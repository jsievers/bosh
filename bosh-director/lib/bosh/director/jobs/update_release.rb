require 'securerandom'
require 'common/version/release_version'

module Bosh::Director
  module Jobs
    class UpdateRelease < BaseJob
      include LockHelper
      include DownloadHelper

      @queue = :normal
      @compiled_release = false

      attr_accessor :release_model

      def self.job_type
        :update_release
      end

      # @param [String] release_path local path or remote url of the release archive
      # @param [Hash] options Release update options
      def initialize(release_path, options = {})
        if options['remote']
          # file will be downloaded to the release_path
          @release_path = File.join(Dir.tmpdir, "release-#{SecureRandom.uuid}")
          @release_url = release_path
        else
          # file already exists at the release_path
          @release_path = release_path
        end

        @release_model = nil
        @release_version_model = nil

        @rebase = !!options['rebase']
        @skip_if_exists = !!options['skip_if_exists']

        @manifest = nil
        @name = nil
        @version = nil

        @packages_unchanged = false
        @jobs_unchanged = false
      end

      # Extracts release tarball, verifies release manifest and saves release in DB
      # @return [void]
      def perform
        logger.info("Processing update release")
        logger.info("Release rebase will be performed") if @rebase

        single_step_stage("Downloading remote release") { download_remote_release } if @release_url

        release_dir = nil
        single_step_stage("Extracting release") { release_dir = extract_release }

        single_step_stage("Verifying manifest") { verify_manifest(release_dir) }

        with_release_lock(@name) {
          process_release(release_dir)
        }

        if @rebase && @packages_unchanged && @jobs_unchanged
          raise DirectorError, "Rebase is attempted without any job or package changes"
        end

        "Created release `#{@name}/#{@version}'"

      rescue Exception => e
        remove_release_version_model
        raise e

      ensure
        FileUtils.rm_rf(release_dir) if release_dir
        FileUtils.rm_rf(@release_path) if @release_path
      end

      def download_remote_release
        download_remote_file('release', @release_url, @release_path)
      end

      # Extracts release tarball
      # @return [void]
      def extract_release
        release_dir = Dir.mktmpdir

        result = Bosh::Exec.sh("tar -C #{release_dir} -xzf #{@release_path} 2>&1", :on_error => :return)
        if result.failed?
          logger.error("Failed to extract release archive '#{@release_path}' into dir '#{release_dir}', " +
                       "tar returned #{result.exit_status}, " +
                       "output: #{result.output}")
          raise ReleaseInvalidArchive, "Extracting release archive failed. Check task debug log for details."
        end

        release_dir
      end

      # @param [String] release_dir local path to the unpacked release
      # @return [void]
      def verify_manifest(release_dir)
        manifest_file = File.join(release_dir, "release.MF")
        unless File.file?(manifest_file)
          raise ReleaseManifestNotFound, "Release manifest not found"
        end

        @manifest = Psych.load_file(manifest_file)

        #handle compiled_release case
        @compiled_release = !!@manifest["compiled_packages"]
        if @compiled_release
          @packages_folder = "compiled_packages"
        else
          @packages_folder = "packages"
        end

        normalize_manifest

        @name = @manifest["name"]

        begin
          @version = Bosh::Common::Version::ReleaseVersion.parse(@manifest["version"])
          unless @version == @manifest["version"]
            logger.info("Formatted version '#{@manifest["version"]}' => '#{@version}'")
          end
        rescue SemiSemantic::ParseError
          raise ReleaseVersionInvalid, "Release version invalid: #{@manifest["version"]}"
        end

        @commit_hash = @manifest.fetch("commit_hash", nil)
        @uncommitted_changes = @manifest.fetch("uncommitted_changes", nil)
      end

      # Processes uploaded release, creates jobs and packages in DB if needed
      # @param [String] release_dir local path to the unpacked release
      # @return [void]
      def process_release(release_dir)
        @release_model = Models::Release.find_or_create(:name => @name)

        if @rebase
          @version = next_release_version
        end

        version_attrs = {
          :release => @release_model,
          :version => @version.to_s
        }
        version_attrs[:uncommitted_changes] = @uncommitted_changes if @uncommitted_changes
        version_attrs[:commit_hash] = @commit_hash if @commit_hash

        @release_version_model = Models::ReleaseVersion.new(version_attrs)
        unless @release_version_model.valid?
          if @release_version_model.errors[:version] == [:format]
            raise ReleaseVersionInvalid,
              "Release version invalid `#{@name}/#{@version}'"
          elsif @skip_if_exists
            event_log.begin_stage("Release already exists", 1)
            event_log.track("#{@name}/#{@version}") {}
            return
          else
            raise ReleaseAlreadyExists,
              "Release `#{@name}/#{@version}' already exists"
          end
        end

        @release_version_model.save

        single_step_stage("Resolving package dependencies") do
          resolve_package_dependencies(@manifest[@packages_folder])
        end

        @packages = {}
        process_packages(release_dir)
        process_jobs(release_dir)

        event_log.begin_stage(@compiled_release ? "Compiled Release has been created" : "Release has been created", 1)
        event_log.track("#{@name}/#{@version}") {}
      end

      # Normalizes release manifest, so all names, versions, and checksums are Strings.
      # @return [void]
      def normalize_manifest
        Bosh::Director.hash_string_vals(@manifest, 'name', 'version')

        @manifest[@packages_folder].each { |p| Bosh::Director.hash_string_vals(p, 'name', 'version', 'sha1') }
        @manifest['jobs'].each { |j| Bosh::Director.hash_string_vals(j, 'name', 'version', 'sha1') }
      end

      # Resolves package dependencies, makes sure there are no cycles
      # and all dependencies are present
      # @return [void]
      def resolve_package_dependencies(packages)
        packages_by_name = {}
        packages.each do |package|
          packages_by_name[package["name"]] = package
          package["dependencies"] ||= []
        end
        logger.info("Resolving package dependencies for #{packages_by_name.keys.inspect}")

        dependency_lookup = lambda do |package_name|
          packages_by_name[package_name]["dependencies"]
        end
        result = Bosh::Director::CycleHelper.check_for_cycle(packages_by_name.keys, :connected_vertices => true, &dependency_lookup)

        packages.each do |package|
          name = package["name"]
          dependencies = package["dependencies"]
          all_dependencies = result[:connected_vertices][name]
          logger.info("Resolved package dependencies for `#{name}': #{dependencies.pretty_inspect} => #{all_dependencies.pretty_inspect}")
        end
      end

      # Finds all package definitions in the manifest and sorts them into two
      # buckets: new and existing packages, then creates new packages and points
      # current release version to the existing packages.
      # @param [String] release_dir local path to the unpacked release
      # @return [void]
      def process_packages(release_dir)
        logger.info("Checking for new packages in release")

        new_packages = []
        existing_packages = []

        @manifest[@packages_folder].each do |package_meta|
          # Checking whether we might have the same bits somewhere
          packages = Models::Package.where(fingerprint: package_meta["fingerprint"]).all

          if packages.empty?
            new_packages << package_meta
            next
          end

          existing_package = packages.find do |package|
            package.release_id == @release_model.id &&
            package.name == package_meta["name"] &&
            package.version == package_meta["version"]
          end

          if existing_package
            # clean up 'broken' dependency_set (a bug was including transitives)
            # dependency ordering impacts fingerprint
            # TODO: The following code can be removed after some reasonable time period (added 2014.10.06)
            if existing_package.dependency_set != package_meta['dependencies']
              existing_package.dependency_set = package_meta['dependencies']
              existing_package.save
            end

            existing_packages << [existing_package, package_meta]
          else
            # We found a package with the same fingerprint but different
            # (release, name, version) tuple, so we need to make a copy
            # of the package blob and create a new db entry for it
            package = packages.first
            package_meta["blobstore_id"] = package.blobstore_id
            package_meta["sha1"] = package.sha1
            new_packages << package_meta
          end
        end

        package_stemcell_hashes1 = create_packages(new_packages, release_dir)
        package_stemcell_hashes2 = use_existing_packages(existing_packages)
        consolidated_package_stemcell_hashes = Array(package_stemcell_hashes1) | Array(package_stemcell_hashes2)

        create_compiled_packages(consolidated_package_stemcell_hashes, release_dir)
      end

      # Points release DB model to existing packages described by given metadata
      # @param [Array<Array>] packages Existing packages metadata
      def use_existing_packages(packages)
        return if packages.empty?

        package_stemcell_hashes = []

        single_step_stage("Processing #{packages.size} existing package#{"s" if packages.size > 1}") do
          packages.each do |package, package_meta|
            package_desc = "#{package.name}/#{package.version}"
            logger.info("Using existing package `#{package_desc}'")
            register_package(package)

            if @compiled_release
              stemcells = stemcells_used_by_package(package_meta)
              stemcells.each do |stemcell|
                hash = { "package" => package, "stemcell" => stemcell}
                package_stemcell_hashes << hash
              end
            end
          end
        end

        package_stemcell_hashes
      end

      # Creates packages using provided metadata
      # @param [Array<Hash>] packages Packages metadata
      # @param [String] release_dir local path to the unpacked release
      # @return [Array<Hash>] package & stemcell
      def create_packages(package_metas, release_dir)
        if package_metas.empty?
          @packages_unchanged = true
          return
        end

        package_stemcell_hashes = []
        event_log.begin_stage("Creating new packages", package_metas.size)

        package = package_metas.each do |package_meta|
          package_desc = "#{package_meta["name"]}/#{package_meta["version"]}"
          event_log.track(package_desc) do
            logger.info("Creating new package `#{package_desc}'")
            package = create_package(package_meta, release_dir)
            register_package(package)
            package
          end

          if @compiled_release
            stemcells = stemcells_used_by_package(package_meta)
            stemcells.each do |stemcell|
              hash = { "package" => package, "stemcell" => stemcell}
              package_stemcell_hashes << hash
            end
          end
        end

        package_stemcell_hashes
      end

      def create_compiled_packages(all_compiled_packages, release_dir)
        if all_compiled_packages.nil?
          return
        end

        event_log.begin_stage('Creating new compiled packages', all_compiled_packages.size)

        all_compiled_packages.each do |compiled_package_spec|
          package = compiled_package_spec['package']
          stemcell = compiled_package_spec['stemcell']

          existing_compiled_package = Models::CompiledPackage.where(
              :package_id => package.id,
              :stemcell_id => stemcell.id)

          if existing_compiled_package.empty?
            package_desc = "#{package.name}/#{package.version} for #{stemcell.name}/#{stemcell.version}"
            event_log.track(package_desc) do
              create_compiled_package(package, stemcell, release_dir)
            end
          end
        end
      end

      def stemcells_used_by_package(package_meta)
        if package_meta['stemcell'].nil?
          raise 'stemcell informatiom(operating system/version) should be listed for each package of a compiled tarball'
        end

        values = package_meta['stemcell'].split('/', 2)
        operating_system = values[0]
        stemcell_version = values[1]
        unless operating_system && stemcell_version
          raise 'stemcell informatiom(operating system/version) should be listed for each package of a compiled tarball'
        end

        stemcells = Models::Stemcell.where(:operating_system => operating_system, :version => stemcell_version)
        if stemcells.empty?
          raise "No stemcells matching OS #{operating_system} version #{stemcell_version}"
        end

        stemcells
      end

      def create_compiled_package(package, stemcell, release_dir)
        tgz = File.join(release_dir, 'compiled_packages', "#{package.name}.tgz")
        validate_tgz(tgz, "#{package.name}.tgz")

        compiled_package = Models::CompiledPackage.new

        compiled_package.blobstore_id = BlobUtil.create_blob(tgz)
        compiled_package.sha1 = Digest::SHA1.hexdigest(tgz)

        transitive_dependencies = @release_version_model.transitive_dependencies(package)
        compiled_package.dependency_key = Models::CompiledPackage.create_dependency_key(transitive_dependencies)

        compiled_package.build = Models::CompiledPackage.generate_build_number(package, stemcell)
        compiled_package.package_id = package.id
        compiled_package.stemcell_id = stemcell.id

        compiled_package.save
      end

      # Creates package in DB according to given metadata
      # @param [Hash] package_meta Package metadata
      # @param [String] release_dir local path to the unpacked release
      # @return [void]
      def create_package(package_meta, release_dir)
        name, version = package_meta['name'], package_meta['version']

        package_attrs = {
            :release => @release_model,
            :name => name,
            :sha1 => @compiled_release ? nil : package_meta['sha1'],
            :blobstore_id => nil,
            :fingerprint => package_meta['fingerprint'],
            :version => version
        }

        package = Models::Package.new(package_attrs)
        package.dependency_set = package_meta['dependencies']

        unless @compiled_release
          existing_blob = package_meta['blobstore_id']
          desc = "package '#{name}/#{version}'"

          if existing_blob
            logger.info("Creating #{desc} from existing blob #{existing_blob}")
            package.blobstore_id = BlobUtil.copy_blob(existing_blob)

          else
            logger.info("Creating #{desc} from provided bits")

            package_tgz = File.join(release_dir, 'packages', "#{name}.tgz")
            validate_tgz(package_tgz, desc)
            package.blobstore_id = BlobUtil.create_blob(package_tgz)
          end
        end

        package.save
      end

      def validate_tgz(tgz, desc)
        result = Bosh::Exec.sh("tar -tzf #{tgz} 2>&1", :on_error => :return)
        if result.failed?
          logger.error("Extracting #{desc} archive failed, tar returned #{result.exit_status}, output: #{result.output}")
          raise PackageInvalidArchive, "Extracting #{desc} archive failed. Check task debug log for details."
        end
      end

      # Marks package model as used by release version model
      # @param [Models::Package] package Package model
      # @return [void]
      def register_package(package)
        @packages[package.name] = package
        @release_version_model.add_package(package)
      end

      # Finds job template definitions in release manifest and sorts them into
      # two buckets: new and existing job templates, then creates new job
      # template records in the database and points release version to existing ones.
      # @param [String] release_dir local path to the unpacked release
      # @return [void]
      def process_jobs(release_dir)
        logger.info("Checking for new jobs in release")

        new_jobs = []
        existing_jobs = []

        @manifest["jobs"].each do |job_meta|
          # Checking whether we might have the same bits somewhere
          jobs = Models::Template.where(fingerprint: job_meta["fingerprint"]).all

          template = jobs.find do |job|
            job.release_id == @release_model.id &&
            job.name == job_meta["name"] &&
            job.version == job_meta["version"]
          end

          if template.nil?
            new_jobs << job_meta
          else
            existing_jobs << [template, job_meta]
          end
        end

        create_jobs(new_jobs, release_dir)
        use_existing_jobs(existing_jobs)
      end

      def create_jobs(jobs, release_dir)
        if jobs.empty?
          @jobs_unchanged = true
          return
        end

        event_log.begin_stage("Creating new jobs", jobs.size)
        jobs.each do |job_meta|
          job_desc = "#{job_meta["name"]}/#{job_meta["version"]}"
          event_log.track(job_desc) do
            logger.info("Creating new template `#{job_desc}'")
            template = create_job(job_meta, release_dir)
            register_template(template)
          end
        end
      end

      def create_job(job_meta, release_dir)
        release_job = ReleaseJob.new(job_meta, @release_model, release_dir, @packages, logger)
        release_job.create
      end

      # @param [Array<Array>] jobs Existing jobs metadata
      # @return [void]
      def use_existing_jobs(jobs)
        return if jobs.empty?

        single_step_stage("Processing #{jobs.size} existing job#{"s" if jobs.size > 1}") do
          jobs.each do |template, _|
            job_desc = "#{template.name}/#{template.version}"
            logger.info("Using existing job `#{job_desc}'")
            register_template(template)
          end
        end
      end

      # Marks job template model as being used by release version
      # @param [Models::Template] template Job template model
      # @return [void]
      def register_template(template)
        @release_version_model.add_template(template)
      end

      private

      # Returns the next release version (to be used for rebased release)
      # @return [String]
      def next_release_version
        attrs = {:release_id => @release_model.id}
        models = Models::ReleaseVersion.filter(attrs).all
        strings = models.map(&:version)
        list = Bosh::Common::Version::ReleaseVersionList.parse(strings)
        list.rebase(@version)
      end

      # Removes release version model, along with all packages and templates.
      # @return [void]
      def remove_release_version_model
        return unless @release_version_model && !@release_version_model.new?

        @release_version_model.remove_all_packages
        @release_version_model.remove_all_templates
        @release_version_model.destroy
      end
    end
  end
end

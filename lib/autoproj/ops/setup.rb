module Autoproj
    module Ops
        class Setup < Loader
            include Tools

            attr_reader :manifest

            def osdeps
                manifest.osdeps
            end

            attr_reader :config

            attr_reader :loader

            attr_reader :root_dir

            # Returns the build directory (prefix) for this autoproj installation.
            def build_dir
                File.expand_path(prefix_dir, root_dir)
            end

            # Returns the directory in which autoproj's configuration files are
            # stored
            def config_dir
                File.join(root_dir, 'autoproj')
            end

            # Return the directory in which remote package set definition should be
            # checked out
            def remotes_dir
                File.join(root_dir, ".remotes")
            end

            # Returns the path to the provided configuration file.
            def config_file(file)
                File.join(config_dir, file)
            end
            
            # The directory in which packages will be installed.
            #
            # If it is a relative path, it is relative to the root dir of the
            # installation.
            #
            # The default is "install"
            attr_reader :prefix_dir

            # Change the value of {prefix_dir}
            def prefix_dir=(new_path)
                @prefix_dir = new_path
                config.set('prefix', new_path, true)
            end

            # Returns true if +path+ is part of an autoproj installation
            def self.in_autoproj_installation?(path)
                !!find_root_dir(File.expand_path(path))
            end
            
            # Returns the root directory of the current autoproj installation.
            def self.find_root_dir(dir = Dir.pwd)
                root_dir_rx =
                    if Autobuild.windows? then /^[a-zA-Z]:\\\\$/
                    else /^\/$/
                    end

                while root_dir_rx !~ dir && !File.directory?(File.join(dir, "autoproj"))
                    dir = File.dirname(dir)
                end
                return if root_dir_rx =~ dir

                # Preventing backslashed in path, that might be confusing on some path compares
                if Autobuild.windows?
                    dir = dir.gsub(/\\/,'/')
                end
                dir
            end

            def self.find_current_workspace_dir
                root_dir = find_root_dir
                if !root_dir
                    if ENV['AUTOPROJ_CURRENT_ROOT']
                        root_dir = find_root_dir(ENV['AUTOPROJ_CURRENT_ROOT'])
                    end
                end
                root_dir
            end

            def ruby_executable
                config.get('ruby_executable')
            end

            def initialize(root_dir = Dir.pwd)
                super()

                Encoding.default_internal = Encoding::UTF_8
                Encoding.default_external = Encoding::UTF_8

                @config = Autoproj::Configuration.new
                @loader = Loader.new
                @prefix_dir = 'install'

                @root_dir = self.class.find_current_workspace_dir
                if !root_dir
                    raise UserError, "not in an autoproj installation"
                end
                validate_current_root

                load_config
                config.validate_ruby_executable

                if config.has_value_for?('manifest_source')
                    manifest_vcs = VCSDefinition.from_raw(config.get('manifest_source'))
                end
                @manifest = Manifest.new(self, manifest_vcs)
            end

            def base_setup(root_dir = Dir.pwd)
                Autobuild::Reporting << Autoproj::Reporter.new

                # Remove from LOADED_FEATURES everything that is coming from our
                # configuration directory
                Autobuild::Package.clear

                install_ruby_shims

                config.apply_autobuild_configuration
                self.prefix_dir = config.get('prefix', 'install')

                prepare_environment
                Autobuild.prefix  = build_dir
                Autobuild.srcdir  = root_dir
                Autobuild.logdir = File.join(prefix_dir, 'log')

                load_autoprojrc

                config.each_reused_autoproj_installation do |p|
                    manifest.reuse(p)
                end

                # Initialize the Autoproj.osdeps object by loading the default. The
                # rest is loaded later
                manifest.osdeps.load_default

                load_main_initrb
            end

            def load_config
                config_file = File.join(config_dir, "config.yml")
                if File.exists?(config_file)
                    config.load(config_file, config.reconfigure?)
                end
            end

            def save_config
                config.save(File.join(config_dir, "config.yml"))
            end

            def load_main_initrb
                local_source = LocalPackageSet.new(manifest)
                load_if_present(local_source, local_source.local_dir, "init.rb")
            end

            def install_ruby_shims
                install_suffix = ""
                if match = /ruby(.*)$/.match(RbConfig::CONFIG['RUBY_INSTALL_NAME'])
                    install_suffix = match[1]
                end

                bindir = File.join(build_dir, 'bin')
                FileUtils.mkdir_p bindir
                Autoproj.env_add 'PATH', bindir

                File.open(File.join(bindir, 'ruby'), 'w') do |io|
                    io.puts "#! /bin/sh"
                    io.puts "exec #{ruby_executable} \"$@\""
                end
                FileUtils.chmod 0755, File.join(bindir, 'ruby')

                ['gem', 'irb', 'testrb'].each do |name|
                    # Look for the corresponding gem program
                    prg_name = "#{name}#{install_suffix}"
                    if File.file?(prg_path = File.join(RbConfig::CONFIG['bindir'], prg_name))
                        shim_content = [
                            "#! #{ruby_executable}",
                            "exec \"#{prg_path}\", *ARGV"]
                        File.open(File.join(bindir, name), 'w') do |io|
                            io.write shim_content.join("\n")
                        end
                        FileUtils.chmod 0755, File.join(bindir, name)
                    end
                end
            end

            def validate_current_root
                # Make sure that the currently loaded env.sh is actually us
                if ENV['AUTOPROJ_CURRENT_ROOT'] && !ENV['AUTOPROJ_CURRENT_ROOT'].empty? && (ENV['AUTOPROJ_CURRENT_ROOT'] != root_dir)
                    raise ConfigError.new, "the current environment is for #{ENV['AUTOPROJ_CURRENT_ROOT']}, but you are in #{root_dir}, make sure you are loading the right #{ENV_FILENAME} script !"
                end
            end

            # Initializes the environment variables to a "sane default"
            #
            # Use this in autoproj/init.rb to make sure that the environment will not
            # get polluted during the build.
            def self.isolate_environment
                Autobuild.env_inherit = false
                Autobuild.env_push_path 'PATH', "/usr/local/bin", "/usr/bin", "/bin"
            end

            # Initializes the environment variables to a "sane default"
            #
            # Use this in autoproj/init.rb to make sure that the environment will not
            # get polluted during the build.
            def isolate_environment
                self.class.isolate_environment
            end

            def prepare_environment
                # Set up some important autobuild parameters
                Autobuild.env_inherit 'PATH', 'PKG_CONFIG_PATH', 'RUBYLIB', \
                    'LD_LIBRARY_PATH', 'CMAKE_PREFIX_PATH', 'PYTHONPATH'
                
                Autobuild.env_set 'AUTOPROJ_CURRENT_ROOT', root_dir
                Autobuild.env_set 'RUBYOPT', "-rubygems"
                Autoproj::OSDependencies::PACKAGE_HANDLERS.each do |pkg_mng|
                    pkg_mng.initialize_environment(self)
                end
            end

            def load_configuration(silent = false)
                manifest.each_package_set do |pkg_set|
                    if Gem::Version.new(pkg_set.required_autoproj_version) > Gem::Version.new(Autoproj::VERSION)
                        raise ConfigError.new(pkg_set.source_file), "the #{pkg_set.name} package set requires autoproj v#{pkg_set.required_autoproj_version} but this is v#{Autoproj::VERSION}"
                    end
                end

                # Loads OS package definitions once and for all
                manifest.load_osdeps_from_package_sets

                # Load the required autobuild definitions
                if !silent
                    Autoproj.message("autoproj: loading ...", :bold)
                    if !Autoproj.reconfigure?
                        Autoproj.message("run 'autoproj reconfigure' to change configuration options", :bold)
                        Autoproj.message("and use 'autoproj switch-config' to change the remote source for", :bold)
                        Autoproj.message("autoproj's main build configuration", :bold)
                    end
                end
                manifest.each_autobuild_file do |pkg_set, name|
                    import_autobuild_file pkg_set, name
                end

                # Now, load the package's importer configurations (from the various
                # source.yml files)
                manifest.load_importers

                # Auto-add packages that are
                #  * present on disk
                #  * listed in the layout part of the manifest
                #  * but have no definition
                explicit = manifest.normalized_layout
                explicit.each do |pkg_or_set, layout_level|
                    next if manifest.find_package(pkg_or_set)
                    next if manifest.has_package_set?(pkg_or_set)

                    # This is not known. Check if we can auto-add it
                    full_path = File.expand_path(File.join(root_dir, layout_level, pkg_or_set))
                    next if !File.directory?(full_path)

                    handler, _ = Autoproj.package_handler_for(full_path)
                    if handler
                        Autoproj.message "  auto-adding #{pkg_or_set} #{"in #{layout_level} " if layout_level != "/"}using the #{handler.gsub(/_package/, '')} package handler"
                        in_package_set(manifest.local_package_set, manifest.file) do
                            send(handler, pkg_or_set)
                        end
                    else
                        Autoproj.warn "cannot auto-add #{pkg_or_set}: unknown package type"
                    end
                end

                # We finished loading the configuration files. Not all configuration
                # is done (since we need to process the package setup blocks), but
                # save the current state of the configuration anyway.
                save_config
            end

            def setup_package_directories(pkg)
                pkg_name = pkg.name

                layout =
                    if config.randomize_layout?
                        Digest::SHA256.hexdigest(pkg_name)[0, 12]
                    else manifest.whereis(pkg_name)
                    end

                place =
                    if target = manifest.moved_packages[pkg_name]
                        File.join(layout, target)
                    else
                        File.join(layout, pkg_name)
                    end

                pkg = manifest.find_autobuild_package(pkg_name)
                pkg.srcdir = File.join(root_dir, place)
                pkg.prefix = File.join(build_dir, layout)
                pkg.doc_target_dir = File.join(build_dir, 'doc', pkg_name)
                pkg.logdir = File.join(pkg.prefix, "log")
            end
            
            def setup_all_package_directories
                # Override the package directories from our reused installations
                imported_packages = Set.new
                manifest.reused_installations.each do |imported_manifest|
                    imported_manifest.each do |imported_pkg|
                        imported_packages << imported_pkg.name
                        if pkg = manifest.find_package(imported_pkg.name)
                            pkg.autobuild.srcdir = imported_pkg.srcdir
                            pkg.autobuild.prefix = imported_pkg.prefix
                        end
                    end
                end

                manifest.packages.each_value do |pkg_def|
                    pkg = pkg_def.autobuild
                    next if imported_packages.include?(pkg_def.name)
                    setup_package_directories(pkg)
                end
            end

            def finalize_package_setup
                # Now call the blocks that the user defined in the autobuild files. We do it
                # now so that the various package directories are properly setup
                manifest.packages.each_value do |pkg|
                    pkg.user_blocks.each do |blk|
                        blk[pkg.autobuild]
                    end
                    pkg.setup = true
                end

                manifest.each_package_set do |source|
                    load_if_present(source, source.local_dir, "overrides.rb")
                end

                # Resolve optional dependencies
                manifest.resolve_optional_dependencies

                # And, finally, disable all ignored packages on the autobuild side
                manifest.each_ignored_package do |pkg_name|
                    pkg = manifest.find_package(pkg_name)
                    if !pkg
                        Autoproj.warn "ignore line #{pkg_name} does not match anything"
                    else
                        pkg.disable
                    end
                end

                update_environment(manifest)

                # We now have processed the process setup blocks. All configuration
                # should be done and we can save the configuration data.
                save_config
            end

            # Update autoproj itself
            #
            # It will restart the current process if autoproj got updated unless
            # the AUTOPROJ_RESTARTING environment variable is set to 1
            #
            # @option options [Boolean] :restart_on_update (true) restart the
            #   current process if autoproj got updated
            def update_myself(options = Hash.new)
                options = Kernel.validate_options options,
                    restart_on_update: true

                # This is a guard to avoid infinite recursion in case the user is
                # running autoproj osdeps --force
                if ENV['AUTOPROJ_RESTARTING'] == '1'
                    return
                end

                did_update =
                    begin
                        saved_flag = PackageManagers::GemManager.with_prerelease
                        PackageManagers::GemManager.with_prerelease = Autoproj.config.use_prerelease?
                        OSDependencies.load_default.install(%w{autobuild autoproj})
                    ensure
                        PackageManagers::GemManager.with_prerelease = saved_flag
                    end

                # First things first, see if we need to update ourselves
                if did_update && options[:restart_on_update]
                    puts
                    Autoproj.message 'autoproj and/or autobuild has been updated, restarting autoproj'
                    puts

                    # We updated autobuild or autoproj themselves ... Restart !
                    #
                    # ...But first save the configuration (!)
                    ENV['AUTOPROJ_RESTARTING'] = '1'
                    require 'rbconfig'
                    if defined?(ORIGINAL_ARGV)
                        exec(ruby_executable, $0, *ORIGINAL_ARGV)
                    else
                        exec(ruby_executable, $0, *ARGV)
                    end
                end
            end
        end
    end
end


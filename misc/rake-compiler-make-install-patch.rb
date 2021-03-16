require 'rake/baseextensiontask'

module Rake
  class ExtensionTask < BaseExtensionTask

    # Replace method
    undef define_compile_tasks

    def define_compile_tasks(for_platform = nil, ruby_ver = RUBY_VERSION)
      # platform usage
      platf = for_platform || platform

      binary_path = binary(platf)

      # lib_path
      lib_path = lib_dir

      lib_binary_path = "#{lib_path}/#{binary_path}"
      lib_binary_dir_path = File.dirname(lib_binary_path)

      # tmp_path
      tmp_path = "#{@tmp_dir}/#{platf}/#{@name}/#{ruby_ver}"
      stage_path = "#{@tmp_dir}/#{platf}/stage"

      siteconf_path = "#{tmp_path}/.rake-compiler-siteconf.rb"
      tmp_binary_path = "#{tmp_path}/#{binary_path}"
      tmp_binary_dir_path = File.dirname(tmp_binary_path)
      stage_binary_path = "#{stage_path}/#{lib_path}/#{binary_path}"
      stage_binary_dir_path = File.dirname(stage_binary_path)

      # cleanup and clobbering
      CLEAN.include(tmp_path)
      CLEAN.include(stage_path)
      CLOBBER.include("#{lib_path}/#{binary(platf)}")
      CLOBBER.include("#{@tmp_dir}")

      # directories we need
      directory tmp_path
      directory tmp_binary_dir_path
      directory lib_binary_dir_path
      directory stage_binary_dir_path

      directory File.dirname(siteconf_path)
      # Set paths for "make install" destinations
      file siteconf_path => File.dirname(siteconf_path) do
        File.open(siteconf_path, "w") do |siteconf|
          siteconf.puts "require 'rbconfig'"
          siteconf.puts "require 'mkmf'"
          siteconf.puts "dest_path = mkintpath(#{File.expand_path(lib_path).dump})"
          %w[sitearchdir sitelibdir].each do |dir|
            siteconf.puts "RbConfig::MAKEFILE_CONFIG['#{dir}'] = dest_path"
            siteconf.puts "RbConfig::CONFIG['#{dir}'] = dest_path"
          end
        end
      end

      # copy binary from temporary location to final lib
      # tmp/extension_name/extension_name.{so,bundle} => lib/
      task "copy:#{@name}:#{platf}:#{ruby_ver}" => [lib_binary_dir_path, tmp_binary_path, "#{tmp_path}/Makefile"] do
        # install in lib for native platform only
        unless for_platform
          sh "#{make} install", chdir: tmp_path
        end
      end
      # copy binary from temporary location to staging directory
      task "copy:#{@name}:#{platf}:#{ruby_ver}" => [stage_binary_dir_path, tmp_binary_path] do
        cp tmp_binary_path, stage_binary_path
      end

      # copy other gem files to staging directory
      define_staging_file_tasks(@gem_spec.files, lib_path, stage_path, platf, ruby_ver) if @gem_spec

      # binary in temporary folder depends on makefile and source files
      # tmp/extension_name/extension_name.{so,bundle}
      file tmp_binary_path => [tmp_binary_dir_path, "#{tmp_path}/Makefile"] + source_files do
        jruby_compile_msg = <<-EOF
Compiling a native C extension on JRuby. This is discouraged and a
Java extension should be preferred.
        EOF
        warn_once(jruby_compile_msg) if defined?(JRUBY_VERSION)

        chdir tmp_path do
          sh make
          if binary_path != File.basename(binary_path)
            cp File.basename(binary_path), binary_path
          end
        end
      end

      # makefile depends of tmp_dir and config_script
      # tmp/extension_name/Makefile
      file "#{tmp_path}/Makefile" => [tmp_path, extconf, siteconf_path] do |t|
        options = @config_options.dup

        # include current directory
        include_dirs = ['.'].concat(@config_includes).uniq.join(File::PATH_SEPARATOR)
        cmd = [Gem.ruby, "-I#{include_dirs}", "-r#{File.basename(siteconf_path)}"]

        # build a relative path to extconf script
        abs_tmp_path = (Pathname.new(Dir.pwd) + tmp_path).realpath
        abs_extconf = (Pathname.new(Dir.pwd) + extconf).realpath

        # now add the extconf script
        cmd << abs_extconf.relative_path_from(abs_tmp_path)

        # fake.rb will be present if we are cross compiling
        if t.prerequisites.include?("#{tmp_path}/fake.rb") then
          options.push(*cross_config_options(platf))
        end

        # add options to command
        cmd.push(*options)

        # add any extra command line options
        unless extra_options.empty?
          cmd.push(*extra_options)
        end

        chdir tmp_path do
          # FIXME: Rake is broken for multiple arguments system() calls.
          # Add current directory to the search path of Ruby
          sh cmd.join(' ')
        end
      end

      # compile tasks
      unless Rake::Task.task_defined?('compile') then
        desc "Compile all the extensions"
        task "compile"
      end

      # compile:name
      unless Rake::Task.task_defined?("compile:#{@name}") then
        desc "Compile #{@name}"
        task "compile:#{@name}"
      end

      # Allow segmented compilation by platform (open door for 'cross compile')
      task "compile:#{@name}:#{platf}" => ["copy:#{@name}:#{platf}:#{ruby_ver}"]
      task "compile:#{platf}" => ["compile:#{@name}:#{platf}"]

      # Only add this extension to the compile chain if current
      # platform matches the indicated one.
      if platf == RUBY_PLATFORM then
        # ensure file is always copied
        file "#{lib_path}/#{binary_path}" => ["copy:#{name}:#{platf}:#{ruby_ver}"]

        task "compile:#{@name}" => ["compile:#{@name}:#{platf}"]
        task "compile" => ["compile:#{platf}"]
      end
    end
  end
end

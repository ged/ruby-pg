require 'rbconfig'

# setup_extension will create the needed task
# add wrap all them into 'compile'
# also will set a task named 'native' that will change the supplied
# Gem::Specification and inject into the pre compiled binaries.
# if no gem_spec is supplied, no native task get defined.
def setup_extension(extension_name, gem_spec = nil)
  # use the DLEXT for the true extension name
  ext_name = "#{extension_name}.#{RbConfig::CONFIG['DLEXT']}"

  # getting this file is part of the compile task
  task :compile => ["ext/#{ext_name}"]

  file "ext/#{ext_name}" => "ext/Makefile" do
    # Visual C make utility is named 'nmake', MinGW conforms GCC 'make' standard.
    make_cmd = RUBY_PLATFORM =~ /mswin/ ? 'nmake' : 'make'
    Dir.chdir('ext') do
      sh make_cmd
    end
  end

  file "ext/Makefile" => "ext/extconf.rb" do
    Dir.chdir('ext') do
      ruby 'extconf.rb'
    end
  end

  unless Rake::Task.task_defined?('native')
    if gem_spec
      desc "Build the extensions into native binaries."
      task :native => [:compile] do |t|
        # use CURRENT platform instead of RUBY
        gem_spec.platform = Gem::Platform::CURRENT

        # clear the extension (to avoid RubyGems firing the build process)
        gem_spec.extensions.clear

        # add the precompiled binaries to the list of files 
        # (taken from compile task dependency)
        gem_spec.files += Rake::Task['compile'].prerequisites
      end
    end
  end
end

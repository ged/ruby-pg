
require 'rubygems'
require 'spec'
require 'spec/rake/spectask'
require 'rake'
require 'rake/testtask'
require 'rake/gempackagetask'
require 'rake/rdoctask'

Spec::Rake::SpecTask.new("test") { |t|
	t.spec_files = FileList["spec/*_spec.rb"]
}

task :default do
	Dir.chdir('ext')
	%x( ruby extconf.rb )
	%x( make )
end

task :clean do
	Dir.chdir('ext')
	%x( make clean )
end

task :gem do
	%x( gem build pg.gemspec )
end




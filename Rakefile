
require 'rubygems'
require 'spec'
require 'spec/rake/spectask'
require 'rake'
require 'rake/testtask'
require 'rake/gempackagetask'
require 'rake/rdoctask'

$test_instance_id = rand

Spec::Rake::SpecTask.new("test_pgconn") { |t|
	t.spec_files = ["tests/pg_spec.rb"]
}

Spec::Rake::SpecTask.new("test_pgresult") { |t|
	t.spec_files = ["tests/pgresult_spec.rb"]
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

task :test => %w( test_pgconn test_pgresult )

task :gem do
	%x( gem build pg.gemspec )
end




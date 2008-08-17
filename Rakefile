
require 'rubygems'
require 'rake/clean'
require 'rake/gempackagetask'
require 'spec/rake/spectask'
require 'ext_helper'
require 'date'

# House-keeping
CLEAN.include '**/*.o', '**/*.so', '**/*.bundle', '**/*.a', 
	'**/*.log', "{ext,lib}/*.{bundle,so,obj,pdb,lib,def,exp}",
	"ext/Makefile", 'lib', '**/*.db'

spec = Gem::Specification.new do |s|
	s.name              = 'pg'
	s.rubyforge_project = 'ruby-pg'
	s.version           = "0.7.9.#{Date.today}".tr('-', '.')
	s.summary           = 'Ruby extension library providing an API to PostgreSQL'
	s.authors           = [
		'Yukihiro Matsumoto', 
		'Eiji Matsumoto', 
		'Noboru Saitou', 
		'Dave Lee', 
		'Jeff Davis']
	s.email             = 'ruby-pg@j-davis.com'
	s.homepage          = 'http://rubyforge.org/projects/ruby-pg'
	s.requirements      = 'PostgreSQL libpq library and headers'
	s.has_rdoc          = true
	s.extra_rdoc_files  = ['ext/pg.c']
	s.extensions        = [ 'ext/extconf.rb' ]

	s.files = Dir.glob("README.*, LICENSE, COPYING.txt, ChangeLog, Contributors, GPL, BSD") + Dir.glob("{doc,ext,lib,sample,spec}/**/*").reject { |x| CLEAN.include?(x) }
end

Rake::GemPackageTask.new(spec) do |pkg|
  pkg.gem_spec = spec
end

setup_extension 'pg', spec

desc "Run all specs in spec directory"
Spec::Rake::SpecTask.new("spec") do |t|
  t.spec_opts = ["--format", "specdoc", "--colour"]
  t.spec_files = FileList["spec/**/*_spec.rb"]
end
task :spec => [:compile]

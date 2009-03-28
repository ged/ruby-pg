
require 'rubygems'
require 'rake/clean'
require 'rake/gempackagetask'
require 'spec/rake/spectask'
require 'rake/rdoctask'
require 'ext_helper'
require 'date'

# House-keeping
CLEAN.include '**/*.o', 'ext/*.so', '**/*.bundle', '**/*.a',
	 '**/*.log', "{ext,lib}/*.{bundle,so,obj,pdb,lib,def,exp}",
	"ext/Makefile", 'lib', '**/*.db'

FILES = FileList[
  'Rakefile',
  'README',
  'LICENSE',
  'COPYING.txt',
  'ChangeLog',
  'Contributors',
  'GPL',
  'BSD',
  'doc/**/*',
  'ext/*',
  'ext/mingw/Rakefile',
  'ext/mingw/build.rake',
  'ext/vc/*.sln',
  'ext/vc/*.vcproj',
  'lib/**/*',
  'sample/**/*',
  'spec/**/*'
]

spec = Gem::Specification.new do |s|
	s.name              = 'pg'
  s.platform = Gem::Platform::RUBY
  s.require_path = "lib"
	s.rubyforge_project = 'ruby-pg'
	s.version           = "0.8.0"
  s.date = DateTime.now
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
  s.required_ruby_version = '>= 1.8.4'
	s.files = FILES.to_a.reject { |x| CLEAN.include?(x) }
end

Rake::GemPackageTask.new(spec) do |pkg|
  pkg.gem_spec = spec
  pkg.need_tar = true
end

# ------- Windows Package ----------
if RUBY_PLATFORM.match(/win32/)
  binaries = (FileList['ext/mingw/*.so',
                       'ext/mingw/*.dll*'])

  # Windows specification
  win_spec = spec.clone
  win_spec.extensions = ['ext/mingw/Rakefile']
  win_spec.platform = Gem::Platform::CURRENT
  win_spec.files += binaries.to_a

  # Rake task to build the windows package
  Rake::GemPackageTask.new(win_spec) do |pkg|
  end
end

# ---------  RDoc Documentation ---------
desc "Generate rdoc documentation"
Rake::RDocTask.new("rdoc") do |rdoc|
  rdoc.rdoc_dir = 'doc/rdoc'
  rdoc.title    = "pg"
  # Show source inline with line numbers
  rdoc.options << "--line-numbers"
  # Make the readme file the start page for the generated html
  rdoc.options << '--main' << 'README'
  rdoc.rdoc_files.include('ext/**/*.c',
                          'ChangeLog',
                          'README*',
                          'LICENSE')
end


setup_extension 'pg', spec

desc "Run all specs in spec directory"
Spec::Rake::SpecTask.new("spec") do |t|
  t.spec_opts = ["--format", "specdoc", "--colour"]
  t.spec_files = FileList["spec/**/*_spec.rb"]
end
task :spec => [:compile]

require 'rubygems'
require 'date'

SPEC = Gem::Specification.new do |s|
  s.name              = 'ruby-pg'
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
  s.extra_rdoc_files = ['ext/pg.c']

  if File.exists? 'pg.so' and PLATFORM =~ /mingw|mswin/
    s.platform        = Gem::Platform::WIN32
  else
    s.platform        = Gem::Platform::RUBY
    s.extensions      = ['ext/extconf.rb']
  end

  FILES = [
	'COPYING',
	'COPYING.txt',
	'Contributors',
	'GPL',
	'LICENSE',
	'README',
	]

  EXT_FILES = Dir['ext/*.[ch]']

  s.files = FILES + EXT_FILES

end

if $0 == __FILE__
  Gem::manage_gems
  Gem::Builder.new(SPEC).build
end


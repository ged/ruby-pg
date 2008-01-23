require 'mkmf'

# OS X compatibility, need to set ARCHFLAGS
if(PLATFORM =~ /darwin/) then
	arch = (IO.popen("uname -m").readline.chomp rescue nil)
	ENV['ARCHFLAGS'] = " -arch #{arch} "
end

# windows compatibility, need different library name
if(PLATFORM =~ /mingw|mswin/) then
	$libname = 'ms/libpq.lib'
else
	$libname = 'pq'
end

if RUBY_VERSION < '1.8'
	puts 'This library is for ruby-1.3 or higher.'
	exit 1
end

def config_value(type)
	ENV["POSTGRES_#{type.upcase}"] || pg_config(type)
end

def pg_config(type)
	IO.popen("pg_config --#{type}dir").readline.chomp rescue nil
end

def have_build_env
	have_library($libname) && have_header('libpq-fe.h') && have_header('libpq/libpq-fs.h')
end

dir_config('pgsql', config_value('include'), config_value('lib'))

desired_functions = %w(
	PQconnectionUsedPassword
	PQisthreadsafe
	PQprepare
	PQexecParams
	PQescapeString
	PQescapeStringConn
	lo_create
	pg_encoding_to_char 
	PQsetClientEncoding 
)

if have_build_env
	desired_functions.each(&method(:have_func))
	$OBJS = ['pg.o','compat.o']
	create_makefile("pg")
else
	puts 'Could not find PostgreSQL build environment (libraries & headers): Makefile not created'
end


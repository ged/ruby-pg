require 'mkmf'

# OS X compatibility
if(PLATFORM =~ /darwin/) then
	# test if postgresql is probably universal
	bindir = (IO.popen("pg_config --bindir").readline.chomp rescue nil)
	filetype = (IO.popen("file #{bindir}/pg_config").
		readline.chomp rescue nil)
	# if it's not universal, ARCHFLAGS should be set
	if((filetype !~ /universal binary/) && ENV['ARCHFLAGS'].nil?) then
		arch = (IO.popen("uname -m").readline.chomp rescue nil)
		$stderr.write %{
		===========   WARNING   ===========
		
		You are building this extension on OS X without setting the 
		ARCHFLAGS environment variable, and PostgreSQL does not appear 
		to have been built as a universal binary. If you are seeing this 
		message, that means that the build will probably fail.

		Try setting the environment variable ARCHFLAGS 
		to '-arch #{arch}' before building.

		For example:
		(in bash) $ export ARCHFLAGS='-arch #{arch}'
		(in tcsh) $ setenv ARCHFLAGS '-arch #{arch}'

		Then try building again.

		===================================
		}
		# We don't exit here. Who knows? It might build.
	end
end

# windows compatibility, need different library name
if(PLATFORM =~ /mingw|mswin/) then
	$libname = '/ms/libpq.lib'
else
	$libname = 'pq'
end

if RUBY_VERSION < '1.8'
	puts 'This library is for ruby-1.8 or higher.'
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


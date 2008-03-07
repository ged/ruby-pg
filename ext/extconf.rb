require 'mkmf'

unless system("pg_config --bindir > /dev/null")
	$stderr.write("ERROR: can't find pg_config.\n")
	$stderr.write("HINT: Make sure pg_config is in your PATH\n")
	exit 1
end

# OS X compatibility
if(PLATFORM =~ /darwin/) then
	# test if postgresql is probably universal
	bindir = (IO.popen("pg_config --bindir").readline.chomp rescue nil)
	filetype = (IO.popen("file #{bindir}/pg_config").
		readline.chomp rescue nil)
	# if it's not universal, ARCHFLAGS should be set
	if((filetype !~ /universal binary/) && ENV['ARCHFLAGS'].nil?) then
		arch_tmp = (IO.popen("uname -p").readline.chomp rescue nil)
		if(arch_tmp == 'powerpc') 
			arch = 'ppc'
		else
			arch = 'i386'
		end
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
		(in tcsh) % setenv ARCHFLAGS '-arch #{arch}'

		Then try building again.

		===================================
		}
		# We don't exit here. Who knows? It might build.
	end
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
	(have_library('pq') || have_library('libpq') || have_library('ms/libpq')) &&
   have_header('libpq-fe.h') && have_header('libpq/libpq-fs.h')
end

dir_config('pg', config_value('include'), config_value('lib'))

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


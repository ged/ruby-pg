require 'mkmf'

begin
	IO.popen("pg_config --version").readline.chomp
rescue
	$stderr.write("ERROR: can't find pg_config.\n")
	$stderr.write("HINT: Make sure pg_config is in your PATH\n")
	exit 1
end

### Read the output of a command using the fork+pipe syntax so execution errors 
### propagate to Ruby.
def read_cmd_output( *cmd )
	output = IO.read( '|-' ) or exec( *cmd )
	return output.chomp
end


# OS X compatibility
if RUBY_PLATFORM =~ /darwin/

	# Make the ARCHFLAGS environment variable match the arch flags that
	# PostgreSQL was compiled with.
	bindir = read_cmd_output( 'pg_config', '--bindir' )
	pg_cflags = read_cmd_output( 'pg_config', '--cflags' )

	pg_cflags.scan( /-arch\s+\S+/ ) do |str|
		$stderr.puts "Adding ARCHFLAGS: %p" % [ str ]
		$CFLAGS << ' ' << str
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
	have_header( 'unistd.h' )
	create_makefile("pg")
else
	puts 'Could not find PostgreSQL build environment (libraries & headers): Makefile not created'
end


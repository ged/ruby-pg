if RUBY_VERSION < '1.3'
  puts 'This library is for ruby-1.3 or higher.'
  exit 1
end

require 'mkmf'

def config_value(type)
  ENV["POSTGRES_#{type.upcase}"] || pg_config(type)
end

def pg_config(type)
  IO.popen("pg_config --#{type}dir").readline.chomp rescue nil
end

def have_build_env
  have_library('pq') && have_header('libpq-fe.h') && have_header('libpq/libpq-fs.h')
end

dir_config('pgsql', config_value('include'), config_value('lib'))

desired_functions = %w(
	PQsetClientEncoding 
	PQfreemem 
	PQescapeStringConn
	PQprepare
	PQescapeString
	PQexecParams
	PQconnectionUsedPassword
	PQconnectionNeedsPassword
	PQisthreadsafe
	PQnparams
	PQparamtype
	PQsendDescribePrepared
	PQsendDescribePortal
	PQsendPrepare
	PQencryptPassword
	PQdescribePrepared
	PQdescribePortal
	lo_create
	lo_truncate
	pg_encoding_to_char 
)

if have_build_env
  desired_functions.each(&method(:have_func))
  $OBJS = ['pg.o','compat.o']
  $CFLAGS << ' -Wall -Wmissing-prototypes'
  create_makefile("pg")
else
  puts 'Could not find PostgreSQL build environment (libraries & headers): Makefile not created'
end

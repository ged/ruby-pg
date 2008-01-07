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

required_libraries = []
desired_functions = %w(PQsetClientEncoding pg_encoding_to_char PQfreemem PQserverVersion)
compat_functions = %w(PQescapeString PQexecParams)

if have_build_env
  required_libraries.each(&method(:have_library))
  desired_functions.each(&method(:have_func))
  $objs = ['postgres.o','libpq-compat.o'] if compat_functions.all?(&method(:have_func))
  $CFLAGS << ' -Wall '
  create_makefile("postgres")
else
  puts 'Could not find PostgreSQL build environment (libraries & headers): Makefile not created'
end

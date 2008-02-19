require 'rubygems'
require 'mkrf'

$functions = %w[
	lo_create
    PQconnectionUsedPassword
    PQisthreadsafe
    PQprepare
    PQexecParams
    PQescapeString
    PQescapeStringConn
    lo_create
    pg_encoding_to_char
    PQsetClientEncoding
]

# OS X compatibility
if(PLATFORM =~ /darwin/) then
	# test if postgresql is probably universal
	bindir = escape_path(IO.popen("pg_config --bindir").readline.chomp)
	Open3.popen3('file',"#{bindir}/pg_config") do |the_in, the_out, the_err|
		filetype = the_out.readline.chomp
	end
	# if it's not universal, ARCHFLAGS should be set
	if((filetype !~ /universal binary/) && ENV['ARCHFLAGS'].nil?) then
		arch = IO.popen("uname -m").readline.chomp
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

def escape_path(path)
	if(PLATFORM =~ /mswin|mingw/) then
		'"' + path + '"'
	else
		path.gsub(%r{([^a-zA-Z0-9/._-])}, "\\\\\\1")
	end
end

def pg_config(type)
	IO.popen("pg_config --#{type}dir").readline.chomp
end

def config_value(type)
	escape_path(ENV["POSTGRES_#{type.upcase}"] || pg_config(type))
end

Mkrf::Generator.new('pg', '*.c', 
		{
			:includes => [config_value('include'), Config::CONFIG['includedir'], 
					Config::CONFIG["archdir"], Config::CONFIG['sitelibdir'], "."],
			:library_paths => [config_value('lib')],
			# must set loaded_libs to work around a mkrf bug on some platforms
			:loaded_libs => []
		}
	) do |g|

	$stdout.write("checking for libpq-fe.h... ")
	if g.include_header('libpq-fe.h') &&
	   g.include_header('libpq/libpq-fs.h')
	then
		puts 'yes'
	else
		puts 'no'
		puts 'Could not find PostgreSQL headers: ' +
				'Rakefile not created'
		exit 1
	end

	$stdout.write("checking for libpq... ")
	# we have to check a few possible names to account
	# for building on windows
	if g.include_library('pq') ||
	   g.include_library('libpq') ||
	   g.include_library('ms/libpq')
	then
		puts 'yes'
	else
		puts 'no'
		puts 'Could not find PostgreSQL client library: ' +
				'Rakefile not created'
		exit 1
	end

	$functions.each do |func|
		$stdout.write("checking for #{func}()... ")
		if(g.has_function?(func)) then
			g.add_define("HAVE_#{func.upcase}")
			puts 'yes'
		else
			puts 'no'
		end
	end

	puts "creating Rakefile"
end


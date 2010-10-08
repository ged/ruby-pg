require 'mkmf'

if pgdir = with_config( 'pg' )
	ENV['PATH'] = "#{pgdir}/bin" + File::PATH_SEPARATOR + ENV['PATH']
end


### Turn a version string into a Comparable binary datastructure
def vvec( version )
	version.split( '.' ).collect {|i| Integer(i) }.pack( 'N*' )
end


if vvec(RUBY_VERSION) < vvec('1.8')
	puts 'This library is for ruby-1.8 or higher.'
	exit 1
end

if enable_config( "static-build" )
	
else
	pgconfig = with_config( 'pg-config' ) || 'pg_config'
	if pgconfig = find_executable( pgconfig )
		$CFLAGS << " " + `#{pgconfig} --cflags`.chomp
		$CPPFLAGS << " -I%s" % [ `#{pgconfig} --includedir`.chomp ]
		$LDFLAGS << " -L%s" % [ `#{pgconfig} --libdir`.chomp ]
	end

	# Sort out the universal vs. single-archicture build problems on MacOS X
	if RUBY_PLATFORM.include?( 'darwin' )
		puts "MacOS X build: fixing architecture flags:"
		ruby_archs = Config::CONFIG['CFLAGS'].scan( /-arch (\S+)/ ).flatten
		$stderr.puts "Ruby cflags: %p" % [ Config::CONFIG['CFLAGS'] ]

		# Only keep the '-arch <a>' flags present in both the cflags reported
		# by pg_config and those that Ruby specifies.
		commonflags = nil
		if ENV['ARCHFLAGS']
			puts "  using the value in ARCHFLAGS environment variable (%p)." % [ ENV['ARCHFLAGS'] ]
			common_archs = ENV['ARCHFLAGS'].scan( /-arch\s+(\S+)/ ).flatten

			# Warn if the ARCHFLAGS doesn't have at least one architecture in 
			# common with the running ruby.
			if ( (common_archs & ruby_archs).empty? )
				$stderr.puts '',
					"*** Your ARCHFLAGS setting doesn't seem to contain an architecture in common",
					"with the running ruby interpreter (%p vs. %p)" % [ common_archs, ruby_archs ],
					"I'll continue anyway, but if it fails, try unsetting ARCHFLAGS."
			end

			commonflags = ENV['ARCHFLAGS']
		end

		if pgconfig
			puts "  finding flags common to both Ruby and PostgreSQL..."
			archflags = []
			pgcflags = `#{pgconfig} --cflags`.chomp
			pgarchs = pgcflags.scan( /-arch\s+(\S+)/ ).flatten
			pgarchs.each do |arch|
				puts "  testing for architecture: %p" % [ arch ]
				archflags << "-arch #{arch}" if ruby_archs.include?( arch )
			end

			if archflags.empty?
				$stderr.puts '',
					"*** Your PostgreSQL installation doesn't seem to have an architecture " +
					"in common with the running ruby interpreter (%p vs. %p)" %
					[ pgarchs, ruby_archs ],
					"I'll continue anyway, but if it fails, try setting ARCHFLAGS."
			else
				commonflags = archflags.join(' ')
				puts "  common arch flags: %s" % [ commonflags ]
			end
		else
			$stderr.puts %{
			===========   WARNING   ===========
		
			You are building this extension on OS X without setting the 
			ARCHFLAGS environment variable, and pg_config wasn't found in 
			your PATH. If you are seeing this message, that means that the 
			build will probably fail.

			If it does, you can correct this by either including the path 
			to 'pg_config' in your PATH or setting the environment variable 
			ARCHFLAGS to '-arch <arch>' before building.

			For example:
			(in bash) $ export PATH=/opt/local/lib/postgresql84/bin:$PATH                  
			          $ export ARCHFLAGS='-arch x86_64'
			(in tcsh) % set path = ( /opt/local/lib/postgresql84/bin $PATH )
			          % setenv ARCHFLAGS '-arch x86_64'

			Then try building again.

			===================================
			}.gsub( /^\t+/, '  ' )
		end

		if commonflags
			$CFLAGS.gsub!( /-arch\s+\S+ /, '' )
			$LDFLAGS.gsub!( /-arch\s+\S+ /, '' )
			CONFIG['LDSHARED'].gsub!( /-arch\s+\S+ /, '' )

			$CFLAGS << ' ' << commonflags
			$LDFLAGS << ' ' << commonflags
			CONFIG['LDSHARED'] << ' ' << commonflags
		end
	end
end

dir_config 'pg'

if enable_config("static-build")
	# Link against all required libraries for static build, if they are available
	have_library('gdi32', 'CreateDC') && append_library($libs, 'gdi32')
	have_library('secur32') && append_library($libs, 'secur32')
	have_library('crypto', 'BIO_new') && append_library($libs, 'crypto')
	have_library('ssl', 'SSL_new') && append_library($libs, 'ssl')
end


abort "Can't find the 'libpq-fe.h header" unless have_header( 'libpq-fe.h' )
abort "Can't find the 'libpq/libpq-fs.h header" unless have_header('libpq/libpq-fs.h')

abort "Can't find the PostgreSQL client library (libpq)" unless
	have_library( 'pq', 'PQconnectdb' ) ||
	have_library( 'libpq', 'PQconnectdb' ) ||
	have_library( 'ms/libpq', 'PQconnectdb' )

# optional headers/functions
have_func 'PQconnectionUsedPassword'
have_func 'PQisthreadsafe'
have_func 'PQprepare'
have_func 'PQexecParams'
have_func 'PQescapeString'
have_func 'PQescapeStringConn'
have_func 'lo_create'
have_func 'pg_encoding_to_char'
have_func 'PQsetClientEncoding'

$defs.push( "-DHAVE_ST_NOTIFY_EXTRA" ) if
	have_struct_member 'struct pgNotify', 'extra', 'libpq-fe.h'

# unistd.h confilicts with ruby/win32.h when cross compiling for win32 and ruby 1.9.1
have_header 'unistd.h' unless enable_config("static-build")

create_header()
create_makefile( "pg_ext" )


require 'pp'
require 'mkmf'

if ENV['MAINTAINER_MODE']
	$stderr.puts "Maintainer mode enabled."
	$CFLAGS <<
		' -Wall' <<
		' -ggdb' <<
		' -DDEBUG' <<
		' -pedantic'
	$LDFLAGS <<
		' -ggdb'
end

if pgdir = with_config( 'pg' )
	ENV['PATH'] = "#{pgdir}/bin" + File::PATH_SEPARATOR + ENV['PATH']
end

if enable_config("gvl-unlock", true)
	$defs.push( "-DENABLE_GVL_UNLOCK" )
	$stderr.puts "Calling libpq with GVL unlocked"
else
	$stderr.puts "Calling libpq with GVL locked"
end

if enable_config("cross-build")
	gem 'mini_portile2', '~>2.1'
	require 'mini_portile2'

	OPENSSL_VERSION = ENV['OPENSSL_VERSION'] || '3.3.1'
	OPENSSL_SOURCE_URI = "http://www.openssl.org/source/openssl-#{OPENSSL_VERSION}.tar.gz"

	KRB5_VERSION = ENV['KRB5_VERSION'] || '1.21.3'
	KRB5_SOURCE_URI = "http://kerberos.org/dist/krb5/#{KRB5_VERSION[/^(\d+\.\d+)/]}/krb5-#{KRB5_VERSION}.tar.gz"

	POSTGRESQL_VERSION = ENV['POSTGRESQL_VERSION'] || '16.3'
	POSTGRESQL_SOURCE_URI = "http://ftp.postgresql.org/pub/source/v#{POSTGRESQL_VERSION}/postgresql-#{POSTGRESQL_VERSION}.tar.bz2"

	class BuildRecipe < MiniPortile
		def initialize(name, version, files)
			super(name, version)
			self.files = files
			rootdir = File.expand_path('../..', __FILE__)
			self.target = File.join(rootdir, "ports")
			self.patch_files = Dir[File.join(target, "patches", self.name, self.version, "*.patch")].sort
		end

		def port_path
			"#{target}/#{RUBY_PLATFORM}"
		end

		def cook_and_activate
			checkpoint = File.join(self.target, "#{self.name}-#{self.version}-#{RUBY_PLATFORM}.installed")
			unless File.exist?(checkpoint)
				self.cook
				FileUtils.touch checkpoint
			end
			self.activate
			self
		end
	end

	openssl_platform = with_config("openssl-platform")
	toolchain = with_config("toolchain")

	openssl_recipe = BuildRecipe.new("openssl", OPENSSL_VERSION, [OPENSSL_SOURCE_URI]).tap do |recipe|
		class << recipe
			attr_accessor :openssl_platform
			def configure
				envs = []
				envs << "CFLAGS=-DDSO_WIN32" if RUBY_PLATFORM =~ /mingw|mswin/
				envs << "CFLAGS=-fPIC" if RUBY_PLATFORM =~ /linux/
				execute('configure', ['env', *envs, "./Configure", openssl_platform, "-static", "CROSS_COMPILE=#{host}-", configure_prefix], altlog: "config.log")
			end
			def compile
				execute('compile', "#{make_cmd} build_libs")
			end
			def install
				execute('install', "#{make_cmd} install_dev")
			end
		end

		recipe.openssl_platform = openssl_platform
		recipe.host = toolchain
		recipe.cook_and_activate
	end

	if RUBY_PLATFORM =~ /linux/
		krb5_recipe = BuildRecipe.new("krb5", KRB5_VERSION, [KRB5_SOURCE_URI]).tap do |recipe|
			class << recipe
				def work_path
					File.join(super, "src")
				end
			end
			# We specify -fcommon to get around duplicate definition errors in recent gcc.
			# See https://github.com/cockroachdb/cockroach/issues/49734
			recipe.configure_options << "CFLAGS=-fcommon#{" -fPIC" if RUBY_PLATFORM =~ /linux/}"
			recipe.configure_options << "--without-keyutils"
			recipe.host = toolchain
			recipe.cook_and_activate
		end
	end

	postgresql_recipe = BuildRecipe.new("postgresql", POSTGRESQL_VERSION, [POSTGRESQL_SOURCE_URI]).tap do |recipe|
		class << recipe
			def configure_defaults
				[
					"--target=#{host}",
					"--host=#{host}",
					'--with-openssl',
					*(RUBY_PLATFORM=~/linux/ ? ['--with-gssapi'] : []),
					'--without-zlib',
					'--without-icu',
				]
			end
			def compile
				execute 'compile include', "#{make_cmd} -C src/include install"
				execute 'compile interfaces', "#{make_cmd} -C src/interfaces install"
			end
			def install
			end
		end

		recipe.configure_options << "CFLAGS=#{" -fPIC" if RUBY_PLATFORM =~ /linux/}"
		recipe.configure_options << "LDFLAGS=-L#{openssl_recipe.path}/lib -L#{openssl_recipe.path}/lib64 #{"-lgssapi_krb5 -lkrb5 -lk5crypto -lkrb5support" if RUBY_PLATFORM =~ /linux/}"
		recipe.configure_options << "LIBS=-lkrb5 -lcom_err -lk5crypto -lkrb5support -lresolv" if RUBY_PLATFORM =~ /linux/
		recipe.configure_options << "LIBS=-lwsock32 -lgdi32 -lws2_32 -lcrypt32" if RUBY_PLATFORM =~ /mingw|mswin/
		recipe.configure_options << "CPPFLAGS=-I#{openssl_recipe.path}/include"
		recipe.host = toolchain
		recipe.cook_and_activate
	end

	# Avoid dependency to external libgcc.dll on x86-mingw32
	$LDFLAGS << " -static-libgcc"
	# Don't use pg_config for cross build, but --with-pg-* path options
	dir_config('pg', "#{postgresql_recipe.path}/include", "#{postgresql_recipe.path}/lib")
else
	# Native build

	pgconfig = with_config('pg-config') ||
		with_config('pg_config') ||
		find_executable('pg_config')

	if pgconfig && pgconfig != 'ignore'
		$stderr.puts "Using config values from %s" % [ pgconfig ]
		incdir = IO.popen([pgconfig, "--includedir"], &:read).chomp
		libdir = IO.popen([pgconfig, "--libdir"], &:read).chomp
		dir_config 'pg', incdir, libdir

		# Windows traditionally stores DLLs beside executables, not in libdir
		dlldir = RUBY_PLATFORM=~/mingw|mswin/ ? IO.popen([pgconfig, "--bindir"], &:read).chomp : libdir

	elsif checking_for "libpq per pkg-config" do
			_cflags, ldflags, _libs = pkg_config("libpq")
			dlldir = ldflags && ldflags[/-L([^ ]+)/] && $1
		end

	else
		incdir, libdir = dir_config 'pg'
		dlldir = libdir
	end

	# Try to use runtime path linker option, even if RbConfig doesn't know about it.
	# The rpath option is usually set implicit by dir_config(), but so far not
	# on MacOS-X.
	if dlldir && RbConfig::CONFIG["RPATHFLAG"].to_s.empty?
		append_ldflags "-Wl,-rpath,#{dlldir.quote}"
	end

	if /mswin/ =~ RUBY_PLATFORM
		$libs = append_library($libs, 'ws2_32')
	end
end

$stderr.puts "Using libpq from #{dlldir}"

File.write("postgresql_lib_path.rb", <<-EOT)
module PG
	POSTGRESQL_LIB_PATH = #{dlldir.inspect}
end
EOT
$INSTALLFILES = {
	"./postgresql_lib_path.rb" => "$(RUBYLIBDIR)/pg/"
}

if RUBY_VERSION >= '2.3.0' && /solaris/ =~ RUBY_PLATFORM
	append_cppflags( '-D__EXTENSIONS__' )
end

begin
	find_header( 'libpq-fe.h' ) or abort "Can't find the 'libpq-fe.h header"
	find_header( 'libpq/libpq-fs.h' ) or abort "Can't find the 'libpq/libpq-fs.h header"
	find_header( 'pg_config_manual.h' ) or abort "Can't find the 'pg_config_manual.h' header"

	abort "Can't find the PostgreSQL client library (libpq)" unless
		have_library( 'pq', 'PQconnectdb', ['libpq-fe.h'] ) ||
		have_library( 'libpq', 'PQconnectdb', ['libpq-fe.h'] ) ||
		have_library( 'ms/libpq', 'PQconnectdb', ['libpq-fe.h'] )

rescue SystemExit
	install_text = case RUBY_PLATFORM
	when /linux/
	<<-EOT
Please install libpq or postgresql client package like so:
  sudo apt install libpq-dev
  sudo yum install postgresql-devel
  sudo zypper in postgresql-devel
  sudo pacman -S postgresql-libs
EOT
	when /darwin/
	<<-EOT
Please install libpq or postgresql client package like so:
  brew install libpq
EOT
	when /mingw/
	<<-EOT
Please install libpq or postgresql client package like so:
  ridk exec sh -c "pacman -S ${MINGW_PACKAGE_PREFIX}-postgresql"
EOT
	else
	<<-EOT
Please install libpq or postgresql client package.
EOT
	end

	$stderr.puts <<-EOT
*****************************************************************************

Unable to find PostgreSQL client library.

#{install_text}
or try again with:
  gem install pg -- --with-pg-config=/path/to/pg_config

or set library paths manually with:
  gem install pg -- --with-pg-include=/path/to/libpq-fe.h/ --with-pg-lib=/path/to/libpq.so/

EOT
	raise
end

if /mingw/ =~ RUBY_PLATFORM && RbConfig::MAKEFILE_CONFIG['CC'] =~ /gcc/
	# Work around: https://sourceware.org/bugzilla/show_bug.cgi?id=22504
	checking_for "workaround gcc version with link issue" do
		`#{RbConfig::MAKEFILE_CONFIG['CC']} --version`.chomp =~ /\s(\d+)\.\d+\.\d+(\s|$)/ &&
			$1.to_i >= 6 &&
			have_library(':libpq.lib') # Prefer linking to libpq.lib over libpq.dll if available
	end
end

have_func 'PQconninfo', 'libpq-fe.h' or
	abort "Your PostgreSQL is too old. Either install an older version " +
	      "of this gem or upgrade your database to at least PostgreSQL-9.3."
# optional headers/functions
have_func 'PQsslAttribute', 'libpq-fe.h' # since PostgreSQL-9.5
have_func 'PQresultVerboseErrorMessage', 'libpq-fe.h' # since PostgreSQL-9.6
have_func 'PQencryptPasswordConn', 'libpq-fe.h' # since PostgreSQL-10
have_func 'PQresultMemorySize', 'libpq-fe.h' # since PostgreSQL-12
have_func 'PQenterPipelineMode', 'libpq-fe.h' do |src| # since PostgreSQL-14
  # Ensure header files fit as well
  src + " int con(){ return PGRES_PIPELINE_SYNC; }"
end
have_func 'timegm'
have_func 'rb_gc_adjust_memory_usage' # since ruby-2.4
have_func 'rb_gc_mark_movable' # since ruby-2.7
have_func 'rb_io_wait' # since ruby-3.0
have_func 'rb_io_descriptor' # since ruby-3.1

# unistd.h confilicts with ruby/win32.h when cross compiling for win32 and ruby 1.9.1
have_header 'unistd.h'
have_header 'inttypes.h'
have_header('ruby/fiber/scheduler.h') if RUBY_PLATFORM=~/mingw|mswin/

checking_for "C99 variable length arrays" do
	$defs.push( "-DHAVE_VARIABLE_LENGTH_ARRAYS" ) if try_compile('void test_vla(int l){ int vla[l]; }')
end

create_header()
create_makefile( "pg_ext" )


# -*- ruby -*-

require 'pathname'
require 'rspec'
require 'shellwords'
require 'pg'
require 'openssl'
require 'objspace'
require_relative 'helpers/scheduler.rb'
require_relative 'helpers/tcp_gate_scheduler.rb'
require_relative 'helpers/tcp_gate_switcher.rb'

DEFAULT_TEST_DIR_STR = Dir.pwd
TEST_DIR_STR = ENV['RUBY_PG_TEST_DIR'] || DEFAULT_TEST_DIR_STR
TEST_DIRECTORY = Pathname.new(TEST_DIR_STR)
DATA_OBJ_MEMSIZE = ObjectSpace.memsize_of(Object.new)

if defined? Ractor
	class Ractor
		# compat with Ruby-3.4 and older
		alias value take unless method_defined? :value
	end
end

module PG::TestingHelpers

	### Automatically wrap a transaction around examples that don't disable it.
	def self::included( mod )
		super

		if mod.respond_to?( :around )

			mod.before( :all ) do
				@port = $pg_server.port
				@conninfo = $pg_server.conninfo
				@unix_socket = $pg_server.unix_socket
				@conn = $pg_server.connect

				# Find a local port that is not in use
				@port_down = @port + 10
				loop do
					@port_down = @port_down + 1
					begin
						TCPSocket.new("::1", @port_down)
					rescue SystemCallError
						begin
							TCPSocket.new("127.0.0.1", @port_down)
						rescue SystemCallError
							break
						end
					end
				end
			end

			mod.around( :each ) do |example|
				begin
					@conn.set_client_encoding "UTF8"
					@conn.set_default_encoding
					@conn.exec( 'BEGIN' ) unless example.metadata[:without_transaction]
					desc = example.source_location.join(':')
					@conn.exec %Q{SET application_name TO '%s'} %
						[@conn.escape_string(desc.slice(-60))]
					example.run
				ensure
					if @conn.respond_to?(:exit_pipeline_mode) &&
							@conn.pipeline_status != PG::PQ_PIPELINE_OFF
						@conn.pipeline_sync
						# Fetch results until two successive nil's
						loop do
							unless @conn.get_result
								break unless @conn.get_result
							end
						end
						@conn.exit_pipeline_mode
					end
					@conn.setnonblocking false
					@conn.type_map_for_results = PG::TypeMapAllStrings.new
					@conn.type_map_for_queries = PG::TypeMapAllStrings.new
					@conn.encoder_for_put_copy_data = nil
					@conn.decoder_for_get_copy_data = nil
					@conn.exec( 'ROLLBACK' ) unless example.metadata[:without_transaction]
				end
			end

			mod.after( :all ) do
				if @conn
					check_for_lingering_connections( @conn )
					@conn.finish
				end
			end
		end

	end


	#
	# Examples
	#

	# Set some ANSI escape code constants (Shamelessly stolen from Perl's
	# Term::ANSIColor by Russ Allbery <rra@stanford.edu> and Zenin <zenin@best.com>
	ANSI_ATTRIBUTES = {
		'clear'      => 0,
		'reset'      => 0,
		'bold'       => 1,
		'dark'       => 2,
		'underline'  => 4,
		'underscore' => 4,
		'blink'      => 5,
		'reverse'    => 7,
		'concealed'  => 8,

		'black'      => 30,   'on_black'   => 40,
		'red'        => 31,   'on_red'     => 41,
		'green'      => 32,   'on_green'   => 42,
		'yellow'     => 33,   'on_yellow'  => 43,
		'blue'       => 34,   'on_blue'    => 44,
		'magenta'    => 35,   'on_magenta' => 45,
		'cyan'       => 36,   'on_cyan'    => 46,
		'white'      => 37,   'on_white'   => 47
	}


	###############
	module_function
	###############

	module Loggable
		### Create a string that contains the ANSI codes specified and return it
		def ansi_code( *attributes )
			attributes.flatten!
			attributes.collect! {|at| at.to_s }

			return '' unless /(?:vt10[03]|xterm(?:-color)?|linux|screen)/i =~ ENV['TERM']
			attributes = ANSI_ATTRIBUTES.values_at( *attributes ).compact.join(';')

			# $stderr.puts "  attr is: %p" % [attributes]
			if attributes.empty?
				return ''
			else
				return "\e[%sm" % attributes
			end
		end


		### Colorize the given +string+ with the specified +attributes+ and return it, handling
		### line-endings, color reset, etc.
		def colorize( *args )
			string = ''

			if block_given?
				string = yield
			else
				string = args.shift
			end

			ending = string[/(\s)$/] || ''
			string = string.rstrip

			return ansi_code( args.flatten ) + string + ansi_code( 'reset' ) + ending
		end


		### Output a message with highlighting.
		def message( *msg )
			$stderr.puts( colorize(:bold) { msg.flatten.join(' ') } )
		end


		### Output a logging message if $VERBOSE is true
		def trace( *msg )
			return unless $VERBOSE
			output = colorize( msg.flatten.join(' '), 'yellow' )
			$stderr.puts( output )
		end


		### Return the specified args as a string, quoting any that have a space.
		def quotelist( *args )
			return args.flatten.collect {|part| part.to_s =~ /\s/ ? part.to_s.inspect : part.to_s }
		end


		### Run the specified command +cmd+ with system(), failing if the execution
		### fails.
		def run( *cmd )
			cmd.flatten!

			if cmd.length > 1
				trace( quotelist(*cmd) )
			else
				trace( cmd )
			end

			system( *cmd )
			raise "Command failed: [%s]" % [cmd.join(' ')] unless $?.success?
		end


		### Run the specified command +cmd+ after redirecting stdout and stderr to the specified
		### +logpath+, failing if the execution fails.
		def log_and_run( logpath, *cmd )
			cmd.flatten!

			if cmd.length > 1
				trace( quotelist(*cmd) )
			else
				trace( cmd )
			end

			# Eliminate the noise of creating/tearing down the database by
			# redirecting STDERR/STDOUT to a logfile
			File.open( logpath, File::WRONLY|File::CREAT|File::APPEND ) do |logfh|
				# Seek manually on Windows to the end of the log file, otherwise the content is overwritten.
				logfh.seek(0, :END) if RUBY_PLATFORM =~ /mingw|mswin/
				system( *cmd, [STDOUT, STDERR] => logfh )
			end

			raise "Command failed: [%s]" % [cmd.join(' ')] unless $?.success?
		end
	end

	extend Loggable

	### Check the current directory for directories that look like they're
	### testing directories from previous tests, and tell any postgres instances
	### running in them to shut down.
	def stop_existing_postmasters
		# tmp_test_0.22329534700318
		pat = Pathname.getwd + 'tmp_test_*'
		Pathname.glob( pat.to_s ).each do |testdir|
			datadir = testdir + 'data'
			pidfile = datadir + 'postmaster.pid'
			if pidfile.exist? && pid = pidfile.read.chomp.to_i
				trace "pidfile (%p) exists: %d" % [ pidfile, pid ]
				begin
					Process.kill( 0, pid )
				rescue Errno::ESRCH
					trace "No postmaster running for %s" % [ datadir ]
					# Process isn't alive, so don't try to stop it
				else
					trace "Stopping lingering database at PID %d" % [ pid ]
					run 'pg_ctl', '-D', datadir.to_s, '-m', 'fast', 'stop'
				end
			else
				trace "No pidfile (%p)" % [ pidfile ]
			end
		end
	end

	class PostgresServer
		include Loggable

		attr_reader :port
		attr_reader :conninfo
		attr_reader :unix_socket
		attr_reader :pgdata

		### Set up a PostgreSQL database instance for testing.
		def initialize( name, port: 23456, postgresql_conf: '' )
			trace "Setting up test database for #{name}"
			@name = name
			@port = port
			@test_dir = TEST_DIRECTORY + "tmp_test_#{@name}"
			@pgdata = @test_dir + 'data'
			@pgdata.mkpath
			@pg_bin_dir = nil

			@logfile = @test_dir + 'setup.log'
			trace "Command output logged to #{@logfile}"

			begin
				unless (@pgdata+"postgresql.conf").exist?
					FileUtils.rm_rf( @pgdata, :verbose => $DEBUG )
					trace "Running initdb"
					log_and_run @logfile, pg_bin_path('initdb'), '-E', 'UTF8', '--no-locale', '-D', @pgdata.to_s
				end

				unless (@pgdata+"ruby-pg-server-cert").exist?
					trace "Enable SSL"
					# Enable SSL in server config
					File.open(@pgdata+"postgresql.conf", "a+") do |fd|
						fd.puts <<-EOT
ssl = on
ssl_ca_file = 'ruby-pg-ca-cert'
ssl_cert_file = 'ruby-pg-server-cert'
ssl_key_file = 'ruby-pg-server-key'
#{postgresql_conf}
EOT
					end

					# Enable MD5 authentication in hba config
					hba_content = File.read(@pgdata+"pg_hba.conf")
					File.open(@pgdata+"pg_hba.conf", "w") do |fd|
						fd.puts <<-EOT
# TYPE  DATABASE     USER              ADDRESS             METHOD
host    all          testusermd5       ::1/128             md5
EOT
						fd.puts hba_content
					end

					trace "Generate certificates"
					generate_ssl_certs(@pgdata.to_s)
				end

				trace "Starting postgres"
				sopt = "-p #{@port}"
				sopt += " -k #{@test_dir.to_s.dump}" unless RUBY_PLATFORM=~/mingw|mswin/i
				log_and_run @logfile, pg_bin_path('pg_ctl'), '-w', '-o', sopt,
					'-D', @pgdata.to_s, 'start'
				sleep 2

				td = @pgdata
				@conninfo = "host=localhost port=#{@port} dbname=test sslrootcert=#{td + 'ruby-pg-ca-cert'} sslcert=#{td + 'ruby-pg-client-cert'} sslkey=#{td + 'ruby-pg-client-key'}"
				@unix_socket = @test_dir.to_s
			rescue => err
				$stderr.puts "%p during test setup: %s" % [ err.class, err.message ]
				$stderr.puts "See #{@logfile} for details:"
				$stderr.puts File.read(@logfile) if File.exist?(@logfile)
				$stderr.puts err.backtrace if $DEBUG
				fail
			end
		end

		def generate_ssl_certs(output_dir)
			gen = CertGenerator.new(output_dir)

			trace "create ca-key"
			ca_key = gen.create_key('ruby-pg-ca-key')
			ca_cert = gen.create_ca_cert('ruby-pg-ca-cert', ca_key, '/CN=ruby-pg root key')

			trace "create server cert"
			key = gen.create_key('ruby-pg-server-key')
			csr = gen.create_signing_request('ruby-pg-server-csr', '/CN=localhost', key)
			gen.create_cert_from_csr('ruby-pg-server-cert', csr, ca_cert, ca_key, dns_names: %w[localhost] )

			trace "create client cert"
			key = gen.create_key('ruby-pg-client-key')
			csr = gen.create_signing_request('ruby-pg-client-csr', '/CN=ruby-pg client', key)
			gen.create_cert_from_csr('ruby-pg-client-cert', csr, ca_cert, ca_key)
		end

		def create_test_db
			trace "Creating the test DB"
			log_and_run @logfile, pg_bin_path('psql'), '-p', @port.to_s, '-e', '-c', 'DROP DATABASE IF EXISTS test', 'postgres'
			log_and_run @logfile, pg_bin_path('createdb'), '-p', @port.to_s, '-e', 'test'
		end

		def connect
			conn = PG.connect( @conninfo )
			conn.set_notice_processor do |message|
				$stderr.puts( @name + ':' + message ) if $DEBUG
			end

			return conn
		end

		def teardown
			trace "Tearing down test database for #{@name}"

			log_and_run @logfile, pg_bin_path('pg_ctl'), '-D', @pgdata.to_s, '-m', 'fast', 'stop'
		end

		def pg_bin_path(cmd)
			@pg_bin_dir ||= begin
				`pg_config --bindir`.strip
			rescue
				nil
			end
			# Avoid execution of MSYS2 bash wrapper on Windows while PostgreSQL's restart with restricted privileges:
			cmd += ".exe" if RUBY_PLATFORM=~/mingw|mswin/
			[@pg_bin_dir&.empty? ? nil : @pg_bin_dir, cmd].compact.join("/")
		end
	end

	class CertGenerator
		attr_reader :output_dir

		def initialize(output_dir='.')
			@output_dir = output_dir
			@serial = Time.now.to_i
		end

		def next_serial
			@serial += 1
		end

		def create_ca_cert(name, ca_key, x509_name, valid_years: 10)
			ca_key = OpenSSL::PKey::RSA.new File.read "#{ca_key}" unless ca_key.kind_of?(OpenSSL::PKey::RSA)
			ca_name = OpenSSL::X509::Name.parse x509_name

			ca_cert = OpenSSL::X509::Certificate.new
			ca_cert.serial = next_serial
			ca_cert.version = 2
			ca_cert.not_before = Time.now
			ca_cert.not_after = Time.now + valid_years*365*24*60*60

			ca_cert.public_key = ca_key.public_key
			ca_cert.subject = ca_name
			ca_cert.issuer = ca_name

			extension_factory = OpenSSL::X509::ExtensionFactory.new
			extension_factory.subject_certificate = ca_cert
			extension_factory.issuer_certificate = ca_cert

			ca_cert.add_extension extension_factory.create_extension('subjectKeyIdentifier', 'hash')
			ca_cert.add_extension extension_factory.create_extension('basicConstraints', 'CA:TRUE', true)
			ca_cert.add_extension extension_factory.create_extension('keyUsage', 'cRLSign,keyCertSign', true)

			ca_cert.sign ca_key, OpenSSL::Digest::SHA256.new

			File.open "#{output_dir}/#{name}", 'w' do |io|
				io.puts ca_cert.to_text
				io.write ca_cert.to_pem
			end
			ca_cert
		end

		def create_key(name, rsa_size: 2048)
			ca_key = OpenSSL::PKey::RSA.new rsa_size

			#cipher = OpenSSL::Cipher.new 'AES-128-CBC'

			File.open "#{output_dir}/#{name}", 'w', 0600 do |io|
				io.puts ca_key.to_text
				io.write ca_key.export # (cipher)
			end
			ca_key
		end

		def create_signing_request(name, x509_name, key)
			key = OpenSSL::PKey::RSA.new File.read "#{key}" unless key.kind_of?(OpenSSL::PKey::RSA)
			csr = OpenSSL::X509::Request.new
			csr.version = 0
			csr.subject = OpenSSL::X509::Name.parse x509_name
			csr.public_key = key.public_key
			csr.sign key, OpenSSL::Digest::SHA256.new

			File.open "#{output_dir}/#{name}", 'w' do |io|
				io.puts csr.to_text
				io.write csr.to_pem
			end
			csr
		end

		def create_cert_from_csr(name, csr, ca_cert, ca_key, valid_years: 10, dns_names: nil)
			ca_key = OpenSSL::PKey::RSA.new File.read "#{ca_key}" unless ca_key.kind_of?(OpenSSL::PKey::RSA)
			ca_cert = OpenSSL::X509::Certificate.new File.read "#{ca_cert}" unless ca_cert.kind_of?(OpenSSL::X509::Certificate)
			csr = OpenSSL::X509::Request.new File.read "#{csr}" unless csr.kind_of?(OpenSSL::X509::Request)
			raise 'CSR can not be verified' unless csr.verify csr.public_key

			csr_cert = OpenSSL::X509::Certificate.new
			csr_cert.serial = next_serial
			csr_cert.version = 2
			csr_cert.not_before = Time.now
			csr_cert.not_after = Time.now + valid_years*365*24*60*60

			csr_cert.subject = csr.subject
			csr_cert.public_key = csr.public_key
			csr_cert.issuer = ca_cert.subject

			extension_factory = OpenSSL::X509::ExtensionFactory.new
			extension_factory.subject_certificate = csr_cert
			extension_factory.issuer_certificate = ca_cert

			csr_cert.add_extension extension_factory.create_extension('basicConstraints', 'CA:FALSE')
			csr_cert.add_extension extension_factory.create_extension('keyUsage', 'keyEncipherment,dataEncipherment,digitalSignature')
			csr_cert.add_extension extension_factory.create_extension('subjectKeyIdentifier', 'hash')
			if dns_names
				san = dns_names.map{|n| "DNS:#{n}" }.join(",")
				csr_cert.add_extension extension_factory.create_extension('subjectAltName', san)
			end

			csr_cert.sign ca_key, OpenSSL::Digest::SHA256.new

			open "#{output_dir}/#{name}", 'w' do |io|
				io.puts csr_cert.to_text
				io.write csr_cert.to_pem
			end

			csr_cert
		end
	end

	def check_for_lingering_connections( conn )
		conn.exec( "SELECT * FROM pg_stat_activity" ) do |res|
			conns = res.find_all {|row| row['pid'].to_i != conn.backend_pid && ["client backend", nil].include?(row["backend_type"]) }
			unless conns.empty?
				puts "Lingering connections remain:"
				conns.each do |row|
					puts "  [%s] {%s} %s -- %s" % row.values_at( 'pid', 'state', 'application_name', 'query' )
				end
			end
		end
	end


	# Retrieve the names of the column types of a given result set.
	def result_typenames(res)
		@conn.exec_params( "SELECT " + res.nfields.times.map{|i| "format_type($#{i*2+1},$#{i*2+2})"}.join(","),
				res.nfields.times.flat_map{|i| [res.ftype(i), res.fmod(i)] } ).
				values[0]
	end


	# A matcher for checking the status of a PG::Connection to ensure it's still
	# usable.
	class ConnStillUsableMatcher

		def initialize
			@conn = nil
			@problem = nil
		end

		def matches?( conn )
			@conn = conn
			@problem = self.check_for_problems
			return @problem.nil?
		end

		def check_for_problems
			return "is finished" if @conn.finished?
			return "has bad status" unless @conn.status == PG::CONNECTION_OK
			return "has bad transaction status (%d)" % [ @conn.transaction_status ] unless
				@conn.transaction_status.between?( PG::PQTRANS_IDLE, PG::PQTRANS_INTRANS )
			return "is not usable." unless self.can_exec_query?
			return nil
		end

		def can_exec_query?
			@conn.send_query( "VALUES (1)" )
			@conn.get_last_result.values == [["1"]]
		end

		def failure_message
			return "expected %p to be usable, but it %s" % [ @conn, @problem ]
		end

		def failure_message_when_negated
			"expected %p not to be usable, but it still is" % [ @conn ]
		end

	end


	### Return a ConnStillUsableMatcher to be used like:
	###
	###    expect( pg_conn ).to still_be_usable
	###
	def still_be_usable
		return ConnStillUsableMatcher.new
	end

	def wait_for_polling_ok(conn, meth = :connect_poll)
		status = conn.send(meth)

		while status != PG::PGRES_POLLING_OK
			if status == PG::PGRES_POLLING_READING
				select( [conn.socket_io], [], [], 5.0 ) or
					raise "Asynchronous connection timed out!"

			elsif status == PG::PGRES_POLLING_WRITING
				select( [], [conn.socket_io], [], 5.0 ) or
					raise "Asynchronous connection timed out!"

			elsif status == PG::PGRES_POLLING_FAILED
				break
			end
			status = conn.send(meth)
		end
	end

	def wait_for_query_result(conn)
		result = nil
		loop do
			# Buffer any incoming data on the socket until a full result is ready.
			conn.consume_input
			while conn.is_busy
				select( [conn.socket_io], nil, nil, 5.0 ) or
					raise "Timeout waiting for query response."
				conn.consume_input
			end

			# Fetch the next result. If there isn't one, the query is finished
			result = conn.get_result || break
		end
		result
	end

	def wait_for_flush(conn)
		until conn.flush()
			# wait for the socket to become read- or write-ready
			readable, _writable = IO.select([conn.socket_io], [conn.socket_io])
			if readable.any?
				conn.consume_input
			end
		end
	end

	def scheduler_setup
		# Run examples with gated scheduler
		sched = Helpers::TcpGateScheduler.new(external_host: 'localhost', external_port: ENV['PGPORT'].to_i, debug: ENV['PG_DEBUG']=='1')
		Fiber.set_scheduler(sched)
		@conninfo_gate = @conninfo.gsub(/(^| )port=\d+/, " port=#{sched.internal_port}")

		# Run examples with default scheduler
		#Fiber.set_scheduler(Helpers::Scheduler.new)
		#@conninfo_gate = @conninfo

		# Run examples without scheduler
		#def Fiber.schedule; yield; end
		#@conninfo_gate = @conninfo
	end

	def scheduler_stop
		if Fiber.scheduler && Fiber.scheduler.respond_to?(:finish)
			Fiber.scheduler.finish
		end
	end

	def thread_with_timeout(timeout)
		th = Thread.new do
			yield
		end
		unless th.join(timeout)
			th.kill
			$scheduler_timeout = true
			raise("scheduler timeout in:\n#{th.backtrace.join("\n")}")
		end
	end

	def run_with_scheduler(timeout=10)
		thread_with_timeout(timeout) do
			scheduler_setup

			Fiber.schedule do
				conn = PG.connect(@conninfo_gate)

				yield conn
			ensure
				conn.finish if conn
				scheduler_stop
			end
		end
	end

	def gate_setup
		# Run examples with gate
		gate = Helpers::TcpGateSwitcher.new(external_host: 'localhost', external_port: ENV['PGPORT'].to_i, debug: ENV['PG_DEBUG']=='1')
		@conninfo_gate = @conninfo.gsub(/(^| )port=\d+/, " port=#{gate.internal_port}")

		# Run examples without gate
		#@conninfo_gate = @conninfo
		gate
	end

	def gate_stop(gate)
		gate&.finish
	end

	def run_with_gate(timeout=10)
		thread_with_timeout(timeout) do
			gate = gate_setup
			conn = PG.connect(@conninfo_gate)

			yield conn, gate

			conn.finish
			gate_stop(gate)
		end
	end

	# Define environment variables for the time of the given block
	#
	# All environment variables are restored to the original value or undefined after the block.
	def with_env_vars(**kwargs)
		kwargs = kwargs.map{|k,v| [k.to_s, v && v.to_s] }.to_h
		old_values = kwargs.map{|k,_| [k, ENV[k]] }.to_h
		ENV.update(kwargs)
		begin
			yield
		ensure
			ENV.update(old_values)
		end
	end

	# Append or change 'rubypg_test' host entry in /etc/hosts to a given IP address
	def set_etc_hosts(hostaddr, hostname)
		system "sudo --non-interactive sed -i '/.* #{hostname}$/{h;s/.*/#{hostaddr} #{hostname}/};${x;/^$/{s//#{hostaddr} #{hostname}/;H};x}' /etc/hosts" or skip("unable to change /etc/hosts file")
	end
end


RSpec.configure do |config|
	config.include( PG::TestingHelpers )

	config.run_all_when_everything_filtered = true
	config.filter_run :focus
	config.order = 'random'
	config.mock_with( :rspec ) do |mock|
		mock.syntax = :expect
	end

	if RUBY_PLATFORM =~ /mingw|mswin/
		config.filter_run_excluding :unix
	else
		config.filter_run_excluding :windows
	end

	config.filter_run_excluding( :postgresql_12 ) if PG.library_version < 120000
	config.filter_run_excluding( :postgresql_14 ) if PG.library_version < 140000
	config.filter_run_excluding( :postgresql_17 ) if PG.library_version < 170000
	config.filter_run_excluding( :unix_socket ) if RUBY_PLATFORM=~/mingw|mswin/i
	config.filter_run_excluding( :scheduler ) if RUBY_VERSION < "3.0" || (RUBY_PLATFORM =~ /mingw|mswin/ && RUBY_VERSION < "3.1") || !Fiber.respond_to?(:scheduler)
	config.filter_run_excluding( :scheduler_address_resolve ) if RUBY_VERSION < "3.1"
	config.filter_run_excluding( :ipv6 ) if Addrinfo.getaddrinfo("localhost", nil, nil, :STREAM).size < 2
	config.filter_run_excluding( :ractor ) unless defined?(Ractor)
	begin
		PG.require_bigdecimal_without_warning
	rescue LoadError
		config.filter_run_excluding( :bigdecimal )
	end

	### Automatically set up and tear down the database
	config.before(:suite) do |*args|
		PG::TestingHelpers.stop_existing_postmasters

		ENV['PGHOST'] = 'localhost'
		ENV['PGPORT'] ||= "23456"
		port = ENV['PGPORT'].to_i
		$pg_server = PG::TestingHelpers::PostgresServer.new("specs", port: port)
		$pg_server.create_test_db
	end
	config.after(:suite) do
		$pg_server.teardown
	end
end


# Do not wait for threads doing blocking calls at the process shutdown.
# Instead exit immediately after printing the rspec report, if we know there are pending IO calls, which do not react on ruby interrupts.
END{
	if $scheduler_timeout
		exit!(1)
	end
}

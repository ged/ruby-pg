#!/usr/bin/env ruby

require 'pathname'
require 'rspec'
require 'shellwords'
require 'pg'

TEST_DIRECTORY = Pathname.getwd + "tmp_test_specs"

module PG::TestingHelpers


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
		# redirecting STDERR/STDOUT to a logfile if the Ruby interpreter
		# supports fork()
		logfh = File.open( logpath, File::WRONLY|File::CREAT|File::APPEND )

		if RUBY_PLATFORM =~ /java/
      # FIXME: for some reason redirection in the system method don't
      # work, so I ended up with this lengthy hack
      logpath ||= "/dev/null"
      f = File.open logpath, 'a'
      old_stdout = $stdout
      old_stderr = $stderr
      $stdout = $stderr = f
			system( *cmd )
      $stdout = old_stdout
      $stderr = old_stderr
		else
		  begin
			  pid = fork
		  rescue NotImplementedError
			  logfh.close
      end
			if pid
				logfh.close
			else
				$stdout.reopen( logfh )
				$stderr.reopen( $stdout )
				$stderr.puts( ">>> " + cmd.shelljoin )
				exec( *cmd )
				$stderr.puts "After the exec()?!??!"
				exit!
			end

			Process.wait( pid )
		end

    unless $?.success?
      system("cat #{logpath}")
      raise "Command failed: [%s]" % [cmd.join(' ')]
    end
	end


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
				$stderr.puts "pidfile (%p) exists: %d" % [ pidfile, pid ]
				begin
					Process.kill( 0, pid )
				rescue Errno::ESRCH
					$stderr.puts "No postmaster running for %s" % [ datadir ]
					# Process isn't alive, so don't try to stop it
				else
					$stderr.puts "Stopping lingering database at PID %d" % [ pid ]
					run pg_bin_path('pg_ctl'), '-D', datadir.to_s, '-m', 'fast', 'stop'
				end
			else
				$stderr.puts "No pidfile (%p)" % [ pidfile ]
			end
		end
	end


  def pg_bin_path cmd
    begin
      bin_dir = `pg_config --bindir`.strip
      "#{bin_dir}/#{cmd}"
    rescue
      cmd
    end
  end

	### Set up a PostgreSQL database instance for testing.
	def setup_testing_db( description )
		require 'pg'
		stop_existing_postmasters()

		puts "Setting up test database for #{description}"
		@test_pgdata = TEST_DIRECTORY + 'data'
		@test_pgdata.mkpath

		@port = 54321
		ENV['PGPORT'] = @port.to_s
		ENV['PGHOST'] = 'localhost'
		@conninfo = "host=localhost port=#{@port} dbname=test"

		@logfile = TEST_DIRECTORY + 'setup.log'
		trace "Command output logged to #{@logfile}"

		begin
			unless (@test_pgdata+"postgresql.conf").exist?
				FileUtils.rm_rf( @test_pgdata, :verbose => $DEBUG )
				$stderr.puts "Running initdb"
				log_and_run @logfile, pg_bin_path('initdb'), '-E', 'UTF8', '--no-locale', '-D', @test_pgdata.to_s
			end

			trace "Starting postgres"
			log_and_run @logfile, pg_bin_path('pg_ctl'), 'start', '-l', @logfile.to_s, '-w', '-o', "-k #{TEST_DIRECTORY.to_s.dump}",
				'-D', @test_pgdata.to_s
			sleep 2

			$stderr.puts "Creating the test DB"
			log_and_run @logfile, pg_bin_path('psql'), '-e', '-c', 'DROP DATABASE IF EXISTS test', 'postgres'
			log_and_run @logfile, pg_bin_path('createdb'), '-e', 'test'

		rescue => err
			$stderr.puts "%p during test setup: %s" % [ err.class, err.message ]
			$stderr.puts "See #{@logfile} for details."
			$stderr.puts *err.backtrace if $DEBUG
			fail
		end

		conn = PG.connect( @conninfo )
		conn.set_notice_processor do |message|
			$stderr.puts( description + ':' + message ) if $DEBUG
		end

		return conn
	end


	def teardown_testing_db( conn )
		puts "Tearing down test database"

		if conn
			check_for_lingering_connections( conn )
			conn.finish
		end

		log_and_run @logfile, pg_bin_path('pg_ctl'), 'stop', '-m', 'fast', '-D', @test_pgdata.to_s
	end


	def check_for_lingering_connections( conn )
		conn.exec( "SELECT * FROM pg_stat_activity" ) do |res|
			conns = res.find_all {|row| row['pid'].to_i != conn.backend_pid }
			unless conns.empty?
				puts "Lingering connections remain:"
				conns.each do |row|
					puts "  [%d] {%s} %s -- %s" % row.values_at( 'pid', 'state', 'application_name', 'query' )
				end
			end
		end
	end

	def connection_string_should_contain_application_name(conn_args, app_name)
		conn_name = conn_args.match(/application_name='(.*)'/)[1]
		conn_name.should include(app_name[0..10])
		conn_name.should include(app_name[-10..-1])
		conn_name.length.should <= 64
	end

	# Ensure the connection is in a clean execution status.
	def verify_clean_exec_status
		@conn.send_query( "VALUES (1)" )
		@conn.get_last_result.values.should == [["1"]]
	end
end


RSpec.configure do |config|
	ruby_version_vec = RUBY_VERSION.split('.').map {|c| c.to_i }.pack( "N*" )

	config.include( PG::TestingHelpers )
	config.treat_symbols_as_metadata_keys_with_true_values = true

	config.mock_with :rspec
	config.filter_run_excluding :ruby_19 if ruby_version_vec <= [1,9,1].pack( "N*" )
	if RUBY_PLATFORM =~ /mingw|mswin/
		config.filter_run_excluding :unix
	else
		config.filter_run_excluding :windows
	end
	config.filter_run_excluding :socket_io unless
		PG::Connection.instance_methods.map( &:to_sym ).include?( :socket_io )

	config.filter_run_excluding :postgresql_90 unless
		PG::Connection.instance_methods.map( &:to_sym ).include?( :escape_literal )

	if !PG.respond_to?( :library_version )
		config.filter_run_excluding( :postgresql_91, :postgresql_92, :postgresql_93 )
	elsif PG.library_version < 90200
		config.filter_run_excluding( :postgresql_92, :postgresql_93 )
	elsif PG.library_version < 90300
		config.filter_run_excluding( :postgresql_93 )
	end
end


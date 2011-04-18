#!/usr/bin/env spec
# encoding: utf-8

BEGIN {
	require 'pathname'
	require 'rbconfig'

	basedir = Pathname( __FILE__ ).dirname.parent
	libdir = basedir + 'lib'
	archlib = libdir + Config::CONFIG['sitearch']

	$LOAD_PATH.unshift( basedir.to_s ) unless $LOAD_PATH.include?( basedir.to_s )
	$LOAD_PATH.unshift( libdir.to_s ) unless $LOAD_PATH.include?( libdir.to_s )
	$LOAD_PATH.unshift( archlib.to_s ) unless $LOAD_PATH.include?( archlib.to_s )
}

require 'rspec'
require 'spec/lib/helpers'
require 'pg'
require 'timeout'

describe PGconn do
	include PgTestingHelpers

	before( :all ) do
		@conn = setup_testing_db( "PGconn" )
	end

	before( :each ) do
		@conn.exec( 'BEGIN' )
	end

	it "can create a connection option string from a Hash of options" do
		optstring = PGconn.parse_connect_args( 
			:host => 'pgsql.example.com',
			:dbname => 'db01',
			'sslmode' => 'require'
		  )

		optstring.should be_a( String )
		optstring.should =~ /(^|\s)host='pgsql.example.com'/
		optstring.should =~ /(^|\s)dbname='db01'/
		optstring.should =~ /(^|\s)sslmode='require'/
	end

	it "can create a connection option string from positional parameters" do
		optstring = PGconn.parse_connect_args( 'pgsql.example.com', nil, '-c geqo=off', nil, 
		                                       'sales' )

		optstring.should be_a( String )
		optstring.should =~ /(^|\s)host='pgsql.example.com'/
		optstring.should =~ /(^|\s)dbname='sales'/
		optstring.should =~ /(^|\s)options='-c geqo=off'/
		
		optstring.should_not =~ /port=/
		optstring.should_not =~ /tty=/
	end

	it "can create a connection option string from a mix of positional and hash parameters" do
		optstring = PGconn.parse_connect_args( 'pgsql.example.com',
		                                       :dbname => 'licensing', :user => 'jrandom' )

		optstring.should be_a( String )
		optstring.should =~ /(^|\s)host='pgsql.example.com'/
		optstring.should =~ /(^|\s)dbname='licensing'/
		optstring.should =~ /(^|\s)user='jrandom'/
	end

	it "escapes single quotes and backslashes in connection parameters" do
		PGconn.parse_connect_args( "DB 'browser' \\" ).should == "host='DB \\'browser\\' \\\\'"

	end

	it "connects with defaults if no connection parameters are given" do
		PGconn.parse_connect_args.should == ''
	end

	it "connects successfully with connection string" do
		tmpconn = PGconn.connect(@conninfo)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "connects using 7 arguments converted to strings" do
		tmpconn = PGconn.connect('localhost', @port, nil, nil, :test, nil, nil)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "connects using a hash of connection parameters" do
		tmpconn = PGconn.connect(
			:host => 'localhost',
			:port => @port,
			:dbname => :test)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "raises an exception when connecting with an invalid number of arguments" do
		expect {
			PGconn.connect( 1, 2, 3, 4, 5, 6, 7, 'extra' )
		}.to raise_error( ArgumentError, /extra positional parameter/i )
	end


	it "can connect asynchronously" do
		tmpconn = PGconn.connect_start(@conninfo)
		socket = IO.for_fd(tmpconn.socket)
		status = tmpconn.connect_poll
		while(status != PGconn::PGRES_POLLING_OK) do
			if(status == PGconn::PGRES_POLLING_READING)
				if(not select([socket],[],[],5.0))
					raise "Asynchronous connection timed out!"
				end
			elsif(status == PGconn::PGRES_POLLING_WRITING)
				if(not select([],[socket],[],5.0))
					raise "Asynchronous connection timed out!"
				end
			end
			status = tmpconn.connect_poll
		end
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "doesn't leave stale server connections after finish" do
		PGconn.connect(@conninfo).finish
		sleep 0.5
		res = @conn.exec(%[SELECT COUNT(*) AS n FROM pg_stat_activity
							WHERE usename IS NOT NULL])
		# there's still the global @conn, but should be no more
		res[0]['n'].should == '1'
	end


	EXPECTED_TRACE_OUTPUT = %{
		To backend> Msg Q
		To backend> "SELECT 1 AS one"
		To backend> Msg complete, length 21
		From backend> T
		From backend (#4)> 28
		From backend (#2)> 1
		From backend> "one"
		From backend (#4)> 0
		From backend (#2)> 0
		From backend (#4)> 23
		From backend (#2)> 4
		From backend (#4)> -1
		From backend (#2)> 0
		From backend> D
		From backend (#4)> 11
		From backend (#2)> 1
		From backend (#4)> 1
		From backend (1)> 1
		From backend> C
		From backend (#4)> 13
		From backend> "SELECT 1"
		From backend> Z
		From backend (#4)> 5
		From backend> Z
		From backend (#4)> 5
		From backend> T
		}.gsub( /^\t{2}/, '' ).lstrip

	unless RUBY_PLATFORM =~ /mswin|mingw/
		it "trace and untrace client-server communication" do
			# be careful to explicitly close files so that the
			# directory can be removed and we don't have to wait for
			# the GC to run.
			trace_file = @test_directory + "test_trace.out"
			trace_io = trace_file.open( 'w', 0600 )
			@conn.trace( trace_io )
			trace_io.close

			res = @conn.exec("SELECT 1 AS one")
			@conn.untrace

			res = @conn.exec("SELECT 2 AS two")

			trace_data = trace_file.read

			expected_trace_output = EXPECTED_TRACE_OUTPUT.dup
			# For PostgreSQL < 9.0, the output will be different:
			# -From backend (#4)> 13
			# -From backend> "SELECT 1"
			# +From backend (#4)> 11
			# +From backend> "SELECT"
			if @conn.server_version < 90000
				expected_trace_output.sub!( /From backend \(#4\)> 13/, 'From backend (#4)> 11' )
				expected_trace_output.sub!( /From backend> "SELECT 1"/, 'From backend> "SELECT"' )
			end

			trace_data.should == expected_trace_output
		end
	end

	it "allows a query to be cancelled" do
		error = false
		@conn.send_query("SELECT pg_sleep(1000)")
		@conn.cancel
		tmpres = @conn.get_result
		if(tmpres.result_status != PGresult::PGRES_TUPLES_OK)
			error = true
		end
		error.should == true
	end

	it "automatically rolls back a transaction started with PGconn#transaction if an exception " +
	   "is raised" do
		# abort the per-example transaction so we can test our own
		@conn.exec( 'ROLLBACK' )

		res = nil
		@conn.exec( "CREATE TABLE pie ( flavor TEXT )" )

		expect {
			res = @conn.transaction do
				@conn.exec( "INSERT INTO pie VALUES ('rhubarb'), ('cherry'), ('schizophrenia')" )
				raise "Oh noes! All pie is gone!"
			end
		}.to raise_exception( RuntimeError, /all pie is gone/i )

		res = @conn.exec( "SELECT * FROM pie" )
		res.ntuples.should == 0
	end

	it "not read past the end of a large object" do
		@conn.transaction do
			oid = @conn.lo_create( 0 )
			fd = @conn.lo_open( oid, PGconn::INV_READ|PGconn::INV_WRITE )
			@conn.lo_write( fd, "foobar" )
			@conn.lo_read( fd, 10 ).should be_nil()
			@conn.lo_lseek( fd, 0, PGconn::SEEK_SET )
			@conn.lo_read( fd, 10 ).should == 'foobar'
		end
	end


	it "can wait for NOTIFY events" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )

		pid = fork do
			begin
				conn = PGconn.connect( @conninfo )
				sleep 1
				conn.exec( 'NOTIFY woo' )
			ensure
				conn.finish
				exit!
			end
		end

		@conn.wait_for_notify( 10 ).should == 'woo'
		@conn.exec( 'UNLISTEN woo' )

		Process.wait( pid )
	end

	it "calls a block for NOTIFY events if one is given" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )

		pid = fork do
			begin
				conn = PGconn.connect( @conninfo )
				sleep 1
				conn.exec( 'NOTIFY woo' )
			ensure
				conn.finish
				exit!
			end
		end

		eventpid = event = nil
		@conn.wait_for_notify( 10 ) {|*args| event, eventpid = args }
		event.should == 'woo'
		eventpid.should be_an( Integer )

		@conn.exec( 'UNLISTEN woo' )

		Process.wait( pid )
	end

	it "doesn't collapse sequential notifications" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )
		@conn.exec( 'LISTEN war' )
		@conn.exec( 'LISTEN woz' )

		pid = fork do
			begin
				conn = PGconn.connect( @conninfo )
				conn.exec( 'NOTIFY woo' )
				conn.exec( 'NOTIFY war' )
				conn.exec( 'NOTIFY woz' )
			ensure
				conn.finish
				exit!
			end
		end

		Process.wait( pid )

		channels = []
		3.times do
			channels << @conn.wait_for_notify( 2 )
		end

		channels.should have( 3 ).members
		channels.should include( 'woo', 'war', 'woz' )

		@conn.exec( 'UNLISTEN woz' )
		@conn.exec( 'UNLISTEN war' )
		@conn.exec( 'UNLISTEN woo' )
	end

	it "returns notifications which are already in the queue before wait_for_notify is called " +
	   "without waiting for the socket to become readable" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )

		pid = fork do
			begin
				conn = PGconn.connect( @conninfo )
				conn.exec( 'NOTIFY woo' )
			ensure
				conn.finish
				exit!
			end
		end

		# Wait for the forked child to send the notification
		Process.wait( pid )

		# Cause the notification to buffer, but not be read yet
		@conn.exec( 'SELECT 1' )

		@conn.wait_for_notify( 10 ).should == 'woo'
		@conn.exec( 'UNLISTEN woo' )
	end

	context "under PostgreSQL 9" do

		before( :each ) do
			pending "only works under PostgreSQL 9" if @conn.server_version < 9_00_00
		end

		it "calls the block supplied to wait_for_notify with the notify payload if it accepts " +
		    "any number of arguments" do

			@conn.exec( 'ROLLBACK' )
			@conn.exec( 'LISTEN knees' )

			pid = fork do
				conn = PGconn.connect( @conninfo )
				conn.exec( %Q{NOTIFY knees, 'skirt and boots'} )
				conn.finish
				exit!
			end

			Process.wait( pid )

			event, pid, msg = nil
			@conn.wait_for_notify( 10 ) do |*args|
				event, pid, msg = *args
			end
			@conn.exec( 'UNLISTEN woo' )

			event.should == 'knees'
			pid.should be_a_kind_of( Integer )
			msg.should == 'skirt and boots'
		end

		it "calls the block supplied to wait_for_notify with the notify payload if it accepts " +
		   "two arguments" do

			@conn.exec( 'ROLLBACK' )
			@conn.exec( 'LISTEN knees' )

			pid = fork do
				conn = PGconn.connect( @conninfo )
				conn.exec( %Q{NOTIFY knees, 'skirt and boots'} )
				conn.finish
				exit!
			end

			Process.wait( pid )

			event, pid, msg = nil
			@conn.wait_for_notify( 10 ) do |arg1, arg2|
				event, pid, msg = arg1, arg2
			end
			@conn.exec( 'UNLISTEN woo' )

			event.should == 'knees'
			pid.should be_a_kind_of( Integer )
			msg.should be_nil()
		end

		it "calls the block supplied to wait_for_notify with the notify payload if it " +
		   "doesn't accept arguments" do

			@conn.exec( 'ROLLBACK' )
			@conn.exec( 'LISTEN knees' )

			pid = fork do
				conn = PGconn.connect( @conninfo )
				conn.exec( %Q{NOTIFY knees, 'skirt and boots'} )
				conn.finish
				exit!
			end

			Process.wait( pid )

			notification_received = false
			@conn.wait_for_notify( 10 ) do
				notification_received = true
			end
			@conn.exec( 'UNLISTEN woo' )

			notification_received.should be_true()
		end

		it "calls the block supplied to wait_for_notify with the notify payload if it accepts " +
		   "three arguments" do

			@conn.exec( 'ROLLBACK' )
			@conn.exec( 'LISTEN knees' )

			pid = fork do
				conn = PGconn.connect( @conninfo )
				conn.exec( %Q{NOTIFY knees, 'skirt and boots'} )
				conn.finish
				exit!
			end

			Process.wait( pid )

			event, pid, msg = nil
			@conn.wait_for_notify( 10 ) do |arg1, arg2, arg3|
				event, pid, msg = arg1, arg2, arg3
			end
			@conn.exec( 'UNLISTEN woo' )

			event.should == 'knees'
			pid.should be_a_kind_of( Integer )
			msg.should == 'skirt and boots'
		end

	end

	it "yields the result if block is given to exec" do
		rval = @conn.exec( "select 1234::int as a union select 5678::int as a" ) do |result|
			values = []
			result.should be_kind_of( PGresult )
			result.ntuples.should == 2
			result.each do |tuple|
				values << tuple['a']
			end
			values
		end

		rval.should have( 2 ).members
		rval.should include( '5678', '1234' )
	end


	it "correctly finishes COPY queries passed to #async_exec" do
		@conn.async_exec( "COPY (SELECT 1 UNION ALL SELECT 2) TO STDOUT" )

		results = []
		begin
			data = @conn.get_copy_data( true )
			if false == data
				@conn.block( 2.0 )
				data = @conn.get_copy_data( true )
			end
			results << data if data
		end until data.nil?

		results.should have( 2 ).members
		results.should include( "1\n", "2\n" )
	end


	it "PGconn#block shouldn't block a second thread" do
		t = Thread.new do
			@conn.send_query( "select pg_sleep(3)" )
			@conn.block
		end

		# :FIXME: There's a race here, but hopefully it's pretty small.
		t.should be_alive()

		@conn.cancel
		t.join
	end

	it "PGconn#block should allow a timeout" do
		@conn.send_query( "select pg_sleep(3)" )

		start = Time.now
		@conn.block( 0.1 )
		finish = Time.now

		(finish - start).should be_within( 0.05 ).of( 0.1 )
	end


	it "can encrypt a string given a password and username" do
		PGconn.encrypt_password("postgres", "postgres").
			should =~ /\S+/
	end


	it "raises an appropriate error if either of the required arguments for encrypt_password " +
	   "is not valid" do
		expect {
			PGconn.encrypt_password( nil, nil )
		}.to raise_error( TypeError )
		expect {
			PGconn.encrypt_password( "postgres", nil )
		}.to raise_error( TypeError )
		expect {
			PGconn.encrypt_password( nil, "postgres" )
		}.to raise_error( TypeError )
	end


	it "allows fetching a column of values from a result by column number" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		res.column_values( 0 ).should == %w[1 2 3]
		res.column_values( 1 ).should == %w[2 3 4]
	end


	it "allows fetching a column of values from a result by field name" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		res.field_values( 'column1' ).should == %w[1 2 3]
		res.field_values( 'column2' ).should == %w[2 3 4]
	end


	it "raises an error if selecting an invalid column index" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		expect {
			res.column_values( 20 )
		}.to raise_error( IndexError )
	end


	it "raises an error if selecting an invalid field name" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		expect {
			res.field_values( 'hUUuurrg' )
		}.to raise_error( IndexError )
	end


	it "raises an error if column index is not a number" do
		res = @conn.exec( 'VALUES (1,2),(2,3),(3,4)' )
		expect {
			res.column_values( 'hUUuurrg' )
		}.to raise_error( TypeError )
	end


	it "can connect asynchronously" do
		serv = TCPServer.new( '127.0.0.1', 54320 )
		conn = PGconn.connect_start( '127.0.0.1', 54320, "", "", "me", "xxxx", "somedb" )
		conn.connect_poll.should == PGconn::PGRES_POLLING_WRITING
		select( nil, [IO.for_fd(conn.socket)], nil, 0.2 )
		serv.close
		if conn.connect_poll == PGconn::PGRES_POLLING_READING
			select( [IO.for_fd(conn.socket)], nil, nil, 0.2 )
		end
		conn.connect_poll.should == PGconn::PGRES_POLLING_FAILED
	end

	it "discards previous results (if any) before waiting on an #async_exec"

	it "calls the block if one is provided to #async_exec" do
		result = nil
		@conn.async_exec( "select 47 as one" ) do |pg_res|
			result = pg_res[0]
		end
		result.should == { 'one' => '47' }
	end

	after( :each ) do
		@conn.exec( 'ROLLBACK' )
	end

	after( :all ) do
		teardown_testing_db( @conn )
	end
end

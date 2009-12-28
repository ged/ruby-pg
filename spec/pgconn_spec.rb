#!/usr/bin/env spec
# encoding: utf-8

BEGIN {
	require 'pathname'
	require 'rbconfig'

	basedir = Pathname( __FILE__ ).dirname.parent
	libdir = basedir + 'lib'
	archlib = libdir + Config::CONFIG['sitearch']

	$LOAD_PATH.unshift( libdir.to_s ) unless $LOAD_PATH.include?( libdir.to_s )
	$LOAD_PATH.unshift( archlib.to_s ) unless $LOAD_PATH.include?( archlib.to_s )
}

require 'pg'

require 'rubygems'
require 'spec'
require 'spec/lib/helpers'
require 'timeout'

describe PGconn do
	include PgTestingHelpers

	before( :all ) do
		@conn = setup_testing_db( "PGconn" )
	end

	before( :each ) do
		@conn.exec( 'BEGIN' )
	end


	it "should connect successfully with connection string" do
		tmpconn = PGconn.connect(@conninfo)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "should connect using 7 arguments converted to strings" do
		tmpconn = PGconn.connect('localhost', @port, nil, nil, :test, nil, nil)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "should connect using hash" do
		tmpconn = PGconn.connect(
			:host => 'localhost',
			:port => @port,
			:dbname => :test)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "should connect asynchronously" do
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

	it "should not leave stale server connections after finish" do
		PGconn.connect(@conninfo).finish
		sleep 0.5
		res = @conn.exec(%[SELECT COUNT(*) AS n FROM pg_stat_activity
							WHERE usename IS NOT NULL])
		# there's still the global @conn, but should be no more
		res[0]['n'].should == '1'
	end

	unless RUBY_PLATFORM =~ /mswin|mingw/
		it "should trace and untrace client-server communication" do
			# be careful to explicitly close files so that the
			# directory can be removed and we don't have to wait for
			# the GC to run.
			expected_trace_file = File.join(Dir.getwd, "spec/data", "expected_trace.out")
			expected_trace_data = open(expected_trace_file, 'rb').read
			trace_file = open(File.join(@test_directory, "test_trace.out"), 'wb')
			@conn.trace(trace_file)
			trace_file.close
			res = @conn.exec("SELECT 1 AS one")
			@conn.untrace
			res = @conn.exec("SELECT 2 AS two")
			trace_file = open(File.join(@test_directory, "test_trace.out"), 'rb')
			trace_data = trace_file.read
			trace_file.close
			trace_data.should == expected_trace_data
		end
	end

	it "should cancel a query" do
		error = false
		@conn.send_query("SELECT pg_sleep(1000)")
		@conn.cancel
		tmpres = @conn.get_result
		if(tmpres.result_status != PGresult::PGRES_TUPLES_OK)
			error = true
		end
		error.should == true
	end

	it "should not read past the end of a large object" do
		@conn.transaction do
			oid = @conn.lo_create( 0 )
			fd = @conn.lo_open( oid, PGconn::INV_READ|PGconn::INV_WRITE )
			@conn.lo_write( fd, "foobar" )
			@conn.lo_read( fd, 10 ).should be_nil()
			@conn.lo_lseek( fd, 0, PGconn::SEEK_SET )
			@conn.lo_read( fd, 10 ).should == 'foobar'
		end
	end


	it "should wait for NOTIFY events via select()" do
		@conn.exec( 'ROLLBACK' )
		@conn.exec( 'LISTEN woo' )

		pid = fork do
			conn = PGconn.connect( @conninfo )
			sleep 1
			conn.exec( 'NOTIFY woo' )
			conn.finish
			exit!
		end

		@conn.wait_for_notify( 10 ).should == 'woo'
		@conn.exec( 'UNLISTEN woo' )

		Process.wait( pid )
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
		@conn.exec( 'CREATE TABLE testdata ( val1 int, val2 int )' )
		@conn.exec( 'INSERT INTO testdata VALUES (1,2),(2,3),(3,4)' )
		res = @conn.exec( 'SELECT * FROM testdata' )
		res.column_values( 0 ).should == %w[1 2 3]
		res.column_values( 1 ).should == %w[2 3 4]
	end


	it "allows fetching a column of values from a result by field name" do
		@conn.exec( 'CREATE TABLE testdata ( val1 int, val2 int )' )
		@conn.exec( 'INSERT INTO testdata VALUES (1,2),(2,3),(3,4)' )
		res = @conn.exec( 'SELECT * FROM testdata' )
		res.field_values( 'val1' ).should == %w[1 2 3]
		res.field_values( 'val2' ).should == %w[2 3 4]
	end


	it "raises an error if selecting an invalid column index" do
		@conn.exec( 'CREATE TABLE testdata ( val1 int, val2 int )' )
		@conn.exec( 'INSERT INTO testdata VALUES (1,2),(2,3),(3,4)' )
		res = @conn.exec( 'SELECT * FROM testdata' )
		expect {
			res.column_values( 20 )
		}.to raise_error( IndexError )
	end


	it "raises an error if selecting an invalid field name" do
		@conn.exec( 'CREATE TABLE testdata ( val1 int, val2 int )' )
		@conn.exec( 'INSERT INTO testdata VALUES (1,2),(2,3),(3,4)' )
		res = @conn.exec( 'SELECT * FROM testdata' )
		expect {
			res.field_values( 'hUUuurrg' )
		}.to raise_error( IndexError )
	end


	it "raises an error if column index is not a number" do
		@conn.exec( 'CREATE TABLE testdata ( val1 int, val2 int )' )
		@conn.exec( 'INSERT INTO testdata VALUES (1,2),(2,3),(3,4)' )
		res = @conn.exec( 'SELECT * FROM testdata' )
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


	after( :each ) do
		@conn.exec( 'ROLLBACK' )
	end

	after( :all ) do
		teardown_testing_db( @conn )
	end
end

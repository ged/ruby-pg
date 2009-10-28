#!/usr/bin/env spec
# encoding: utf-8

require 'rubygems'
require 'spec'
require 'spec/lib/helpers'

$LOAD_PATH.unshift('ext')
require 'pg'

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


	after( :each ) do
		@conn.exec( 'ROLLBACK' )
	end

	after( :all ) do
		teardown_testing_db( @conn )
	end
end

require 'rubygems'
require 'spec'

$LOAD_PATH.unshift('ext')
require 'pg'

describe PGconn do

	before( :all ) do
		puts "======  TESTING PGconn  ======"
		@test_directory = "#{Dir.getwd}/tmp_test_#{rand}"
		@test_pgdata = @test_directory + '/data'
		if File.exists?(@test_directory) then
			raise "test directory exists!"
		end
		@conninfo = "host='#{@test_directory}' dbname=test"
		Dir.mkdir(@test_directory)
		Dir.mkdir(@test_pgdata)
		cmds = []
		cmds << "initdb -D '#{@test_pgdata}'"
		cmds << "pg_ctl -D '#{@test_pgdata}' " + 
			%!-o "--unix-socket-directory='#{@test_directory}' ! + 
			%!--listen-addresses=''" ! + 
			"start"
		cmds << "sleep 2"
		cmds << "createdb -h '#{@test_directory}' test"
		cmds.each do |cmd|
			if not system(cmd) then
				raise "Error executing cmd: #{cmd}: #{$?}"
			end
		end
		@conn = PGconn.connect(@conninfo)
	end

	it "should connect successfully with connection string" do
		tmpconn = PGconn.connect(@conninfo)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "should connect using 7 arguments converted to strings" do
		tmpconn = PGconn.connect(@test_directory, 5432, nil, nil, :test, nil, nil)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "should connect using hash" do
		tmpconn = PGconn.connect(
			:host => @test_directory,
			:port => 5432,
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

	it "should trace and untrace client-server communication" do
		# be careful to explicitly close files so that the 
		# directory can be removed and we don't have to wait for
		# the GC to run.
		expected_trace_data = open('spec/data/expected_trace.out').read
		trace_file = open("#{@test_directory}/test_trace.out", 'w')
		@conn.trace(trace_file)
		trace_file.close
		res = @conn.exec("SELECT 1 AS one")
		@conn.untrace
		res = @conn.exec("SELECT 2 AS two")
		trace_file = open("#{@test_directory}/test_trace.out")
		trace_data = trace_file.read
		trace_file.close
		trace_data.should == expected_trace_data
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

	after( :all ) do
		puts ""
		@conn.finish
		cmds = []
		cmds << "pg_ctl -D '#{@test_pgdata}' stop"
		cmds << "rm -rf '#{@test_directory}'"
		cmds.each do |cmd|
			if not system(cmd) then
				raise "Error executing cmd: #{cmd}: #{$?}"
			end
		end
		puts "====== COMPLETED TESTING PGconn  ======"
		puts ""
	end
end

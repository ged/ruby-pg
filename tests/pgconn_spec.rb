require 'rubygems'
require 'spec'

$LOAD_PATH.unshift('../ext')
require 'pg'

describe PGconn do

	before( :all ) do
		puts "----------------"
		puts "Testing PGconn"
		puts "----------------"
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
			%!-o "--unix-socket-directory='#{@test_directory}'" ! + 
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

	it "should connect successfully" do
		tmpconn = PGconn.connect(@conninfo)
		tmpconn.status.should== PGconn::CONNECTION_OK
		tmpconn.finish
	end

	it "should not leave stale server connections after finish" do
		PGconn.connect(@conninfo).finish
		res = @conn.exec("SELECT pg_stat_get_backend_idset()")
		# there's still the global @conn, but should be no more
		res.ntuples.should== 1
	end

	after( :all ) do
		@conn.finish
		cmds = []
		cmds << "pg_ctl -D '#{@test_pgdata}' stop"
		cmds << "rm -rf '#{@test_directory}'"
		cmds.each do |cmd|
			if not system(cmd) then
				raise "Error executing cmd: #{cmd}: #{$?}"
			end
		end
	end
end

# encoding: utf-8

require 'rubygems'
require 'spec'

$LOAD_PATH.unshift('ext')
require 'pg'

describe PGconn do

	before( :all ) do
		puts "Setting up test database for PGresult tests"
		@test_directory = File.join(Dir.getwd, "tmp_test_#{rand}")
		@test_pgdata = File.join(@test_directory, 'data')
		if File.exists?(@test_directory) then
			raise "test directory exists!"
		end
		@port = 54321
		@conninfo = "host=localhost port=#{@port} dbname=test"
		Dir.mkdir(@test_directory)
		Dir.mkdir(@test_pgdata)
		cmds = []
		cmds << "initdb --no-locale -D \"#{@test_pgdata}\" > /dev/null 2>&1"
		cmds << "pg_ctl -w -o \"-p #{@port}\" -D \"#{@test_pgdata}\" start > /dev/null 2>&1"
		cmds << "createdb -p #{@port} test > /dev/null 2>&1"

		cmds.each do |cmd|
			if not system(cmd) then
				raise "Error executing cmd: #{cmd}: #{$?}"
			end
		end
		@conn = PGconn.connect(@conninfo)
	end

	it "should act as an array of hashes" do
		res = @conn.exec("SELECT 1 AS a, 2 AS b")
		res[0]['a'].should== '1'
		res[0]['b'].should== '2'
	end

	it "should insert nil AS NULL and return NULL as nil" do
		res = @conn.exec("SELECT $1::int AS n", [nil])
		res[0]['n'].should == nil
	end

	it "should detect division by zero as SQLSTATE 22012" do
		sqlstate = nil
		begin
			res = @conn.exec("SELECT 1/0")
		rescue PGError => e
			sqlstate = e.result.result_error_field(
				PGresult::PG_DIAG_SQLSTATE).to_i
		end
		sqlstate.should == 22012
	end

	it "should return the same bytes in binary format that are sent in binary format" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		bytes = File.open(binary_file, 'rb').read
		res = @conn.exec('VALUES ($1::bytea)', 
			[ { :value => bytes, :format => 1 } ], 1)
		res[0]['column1'].should== bytes
	end

	it "should return the same bytes in binary format that are sent as inline text" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		in_bytes = File.open(binary_file, 'rb').read
		out_bytes = nil
		@conn.transaction do |conn|
			conn.exec("SET standard_conforming_strings=on")
			res = conn.exec("VALUES ('#{PGconn.escape_bytea(in_bytes)}'::bytea)", [], 1)
			out_bytes = res[0]['column1']
		end
		out_bytes.should== in_bytes
	end

	it "should return the same bytes in text format that are sent in binary format" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		bytes = File.open(binary_file, 'rb').read
		res = @conn.exec('VALUES ($1::bytea)', 
			[ { :value => bytes, :format => 1 } ])
		PGconn.unescape_bytea(res[0]['column1']).should== bytes
	end

	it "should return the same bytes in text format that are sent as inline text" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		in_bytes = File.open(binary_file, 'rb').read

		out_bytes = nil
		@conn.transaction do |conn|
			conn.exec("SET standard_conforming_strings=on")
			res = conn.exec("VALUES ('#{PGconn.escape_bytea(in_bytes)}'::bytea)", [], 0)
			out_bytes = PGconn.unescape_bytea(res[0]['column1'])
		end
		out_bytes.should== in_bytes
	end

	after( :all ) do
		@conn.finish
		cmds = []
		cmds << "pg_ctl -D \"#{@test_pgdata}\" stop > /dev/null 2>&1"
		cmds << "rm -rf \"#{@test_directory}\" > /dev/null 2>&1"
		cmds.each do |cmd|
			if not system(cmd) then
				raise "Error executing cmd: #{cmd}: #{$?}"
			end
		end
	end
end

# encoding: utf-8

require 'rubygems'
require 'spec'

$LOAD_PATH.unshift('ext')
require 'pg'

describe "multinationalization support" do

	RUBY_VERSION_VEC = RUBY_VERSION.split('.').map {|c| c.to_i }.pack("N*")
	MIN_RUBY_VERSION_VEC = [1,9,1].pack('N*')

	before( :all ) do
		if RUBY_VERSION_VEC >= MIN_RUBY_VERSION_VEC
			puts "Setting up test database for m17n tests"
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
	end

	before( :each ) do
		pending "depends on m17n support in Ruby >= 1.9.1" unless
			RUBY_VERSION_VEC >= MIN_RUBY_VERSION_VEC
	end

	it "should return the same bytes in text format that are sent as inline text" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		in_bytes = File.open(binary_file, 'r:ASCII-8BIT').read

		out_bytes = nil
		@conn.transaction do |conn|
			conn.exec("SET standard_conforming_strings=on")
			res = conn.exec("VALUES ('#{PGconn.escape_bytea(in_bytes)}'::bytea)", [], 0)
			out_bytes = PGconn.unescape_bytea(res[0]['column1'])
		end
		out_bytes.should== in_bytes
	end

	describe "rubyforge #22925: m17n support" do
		it "should return results in the same encoding as the client (iso-8859-1)" do
			out_string = nil
			@conn.transaction do |conn|
				conn.internal_encoding = 'iso8859-1'
				res = conn.exec("VALUES ('fantasia')", [], 0)
				out_string = res[0]['column1']
			end
			out_string.should == 'fantasia'
			out_string.encoding.should == Encoding::ISO8859_1
		end

		it "should return results in the same encoding as the client (utf-8)" do
			out_string = nil
			@conn.transaction do |conn|
				conn.internal_encoding = 'utf-8'
				res = conn.exec("VALUES ('世界線航跡蔵')", [], 0)
				out_string = res[0]['column1']
			end
			out_string.should == '世界線航跡蔵'
			out_string.encoding.should == Encoding::UTF_8
		end

		it "should return results in the same encoding as the client (EUC-JP)" do
			out_string = nil
			@conn.transaction do |conn|
				conn.internal_encoding = 'EUC-JP'
				stmt = "VALUES ('世界線航跡蔵')".encode('EUC-JP')
				res = conn.exec(stmt, [], 0)
				out_string = res[0]['column1']
			end
			out_string.should == '世界線航跡蔵'.encode('EUC-JP')
			out_string.encoding.should == Encoding::EUC_JP
		end

		it "the connection should return ASCII-8BIT when the server encoding is SQL_ASCII" do
			@conn.external_encoding.should == Encoding::ASCII_8BIT
		end

		it "works around the unsupported JOHAB encoding" do
			pending "until I figure out what I'm doing wrong" do
				out_string = nil
				@conn.transaction do |conn|
					conn.exec( "set client_encoding = 'JOHAB';" )
					res = conn.exec( "VALUES ('foo')", [], 0 )
					out_string = res[0]['column1']
				end
				out_string.should == 'foo'.encode(Encoding::ASCII_8BIT)
				out_string.encoding.should == Encoding::ASCII_8BIT
			end
		end

		it "should use client encoding for escaped string" do
			original = "string to escape".force_encoding("euc-jp")
			@conn.set_client_encoding("euc_jp")
			escaped  = @conn.escape(original)
			escaped.encoding.should == Encoding::EUC_JP
		end

	end

	after( :all ) do
		if RUBY_VERSION_VEC >= MIN_RUBY_VERSION_VEC
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
end

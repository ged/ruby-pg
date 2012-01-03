#!/usr/bin/env rspec
# encoding: utf-8

BEGIN {
	require 'pathname'
	require 'rbconfig'

	basedir = Pathname( __FILE__ ).dirname.parent
	libdir = basedir + 'lib'
	archlib = libdir + RbConfig::CONFIG['sitearch']

	$LOAD_PATH.unshift( basedir.to_s ) unless $LOAD_PATH.include?( basedir.to_s )
	$LOAD_PATH.unshift( libdir.to_s ) unless $LOAD_PATH.include?( libdir.to_s )
	$LOAD_PATH.unshift( archlib.to_s ) unless $LOAD_PATH.include?( archlib.to_s )
}

require 'rspec'
require 'spec/lib/helpers'
require 'pg'

describe "multinationalization support", :ruby_19 => true do
	include PgTestingHelpers

	before( :all ) do
		@conn = setup_testing_db( "m17n" )
		@conn.exec( 'BEGIN' )
	end

	after( :each ) do
		@conn.exec( 'ROLLBACK' ) if @conn
	end

	after( :all ) do
		teardown_testing_db( @conn ) if @conn
	end


	#
	# Examples
	#

	it "should return the same bytes in text format that are sent as inline text" do
		binary_file = File.join(Dir.pwd, 'spec/data', 'random_binary_data')
		in_bytes = File.open(binary_file, 'r:ASCII-8BIT').read

		out_bytes = nil
		@conn.transaction do |conn|
			conn.exec("SET standard_conforming_strings=on")
			res = conn.exec("VALUES ('#{PGconn.escape_bytea(in_bytes)}'::bytea)", [], 0)
			out_bytes = PGconn.unescape_bytea(res[0]['column1'])
		end
		out_bytes.should == in_bytes
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

		it "returns the results in the correct encoding even if the client_encoding has " +
		   "changed since the results were fetched" do
			out_string = nil
			@conn.transaction do |conn|
				conn.internal_encoding = 'EUC-JP'
				stmt = "VALUES ('世界線航跡蔵')".encode('EUC-JP')
				res = conn.exec(stmt, [], 0)
				conn.internal_encoding = 'utf-8'
				out_string = res[0]['column1']
			end
			out_string.should == '世界線航跡蔵'.encode('EUC-JP')
			out_string.encoding.should == Encoding::EUC_JP
		end

		it "the connection should return ASCII-8BIT when the server encoding is SQL_ASCII" do
			@conn.external_encoding.should == Encoding::ASCII_8BIT
		end

		it "works around the unsupported JOHAB encoding by returning stuff in 'ASCII_8BIT'" do
			pending "figuring out how to create a string in the JOHAB encoding" do
				out_string = nil
				@conn.transaction do |conn|
					conn.exec( "set client_encoding = 'JOHAB';" )
					stmt = "VALUES ('foo')".encode('JOHAB')
					res = conn.exec( stmt, [], 0 )
					out_string = res[0]['column1']
				end
				out_string.should == 'foo'.encode( Encoding::ASCII_8BIT )
				out_string.encoding.should == Encoding::ASCII_8BIT
			end
		end

		it "uses the client encoding for escaped string" do
			original = "string to escape".force_encoding( "euc-jp" )
			@conn.set_client_encoding( "euc_jp" )
			escaped  = @conn.escape( original )
			escaped.encoding.should == Encoding::EUC_JP
		end
	end


	describe "Ruby 1.9.x default_internal encoding" do

		it "honors the Encoding.default_internal if it's set and the synchronous interface is used" do
			@conn.transaction do |txn_conn|
				txn_conn.internal_encoding = Encoding::ISO8859_1
				txn_conn.exec( "CREATE TABLE defaultinternaltest ( foo text )" )
				txn_conn.exec( "INSERT INTO defaultinternaltest VALUES ('Grün und Weiß')" )
			end

			begin
				prev_encoding = Encoding.default_internal
				Encoding.default_internal = Encoding::UTF_8

				conn = PGconn.connect( @conninfo )
				conn.internal_encoding.should == Encoding::UTF_8
				res = conn.exec( "SELECT foo FROM defaultinternaltest" )
				res[0]['foo'].encoding.should == Encoding::UTF_8
			ensure
				conn.finish if conn
				Encoding.default_internal = prev_encoding
			end
		end

	end


	it "encodes exception messages with the connection's encoding (#96)" do
		@conn.set_client_encoding( 'utf-8' )
		@conn.exec "CREATE TABLE foo (bar TEXT)"

		begin
			@conn.exec "INSERT INTO foo VALUES ('Côte d'Ivoire')"
		rescue => err
			err.message.encoding.should == Encoding::UTF_8
		else
			fail "No exception raised?!"
		end
	end

end

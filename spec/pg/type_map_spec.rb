#!/usr/bin/env rspec
# encoding: utf-8

require_relative '../helpers'

require 'pg'


describe PG::TypeMap do
	let!(:tm){ PG::TypeMap.new }

	it "should respond to fit_to_query" do
		expect{ tm.fit_to_query( [123] ) }.to raise_error(NotImplementedError, /not suitable to map query params/)
	end

	it "should respond to fit_to_result" do
		res = @conn.exec( "SELECT 1" )
		expect{ tm.fit_to_result( res ) }.to raise_error(NotImplementedError, /not suitable to map result values/)
	end

	it "should check params type" do
		expect{ tm.fit_to_query( :invalid ) }.to raise_error(TypeError, /expected Array/)
	end

	it "should check result class" do
		expect{ tm.fit_to_result( :invalid ) }.to raise_error(TypeError, /expected kind of PG::Result/)
	end

	it "should raise an error when used for param type casts" do
		expect{
			@conn.exec_params( "SELECT $1", [5], 0, tm )
		}.to raise_error(NotImplementedError, /not suitable to map query params/)
	end

	it "should raise an error when used for result type casts" do
		res = @conn.exec( "SELECT 1" )
		expect{ res.map_types!(tm) }.to raise_error(NotImplementedError, /not suitable to map result values/)
	end
end

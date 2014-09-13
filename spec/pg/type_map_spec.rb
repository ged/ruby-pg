#!/usr/bin/env rspec
# encoding: utf-8

require_relative '../helpers'

require 'pg'


describe PG::TypeMap do

	class Exception_in_fit_to_result < PG::TypeMap
		def fit_to_result(result)
			raise "no mapping defined for result #{result.inspect}"
		end
	end

	it "should raise an error from default oid type conversion" do
		res = @conn.exec( "SELECT 1" )
		expect{
			res.map_types!(Exception_in_fit_to_result.new)
		}.to raise_error(/no mapping defined/)
	end

	class WrongTypeMapBuilder < PG::TypeMap
		def fit_to_result(result)
			:invalid_value
		end
	end

	it "should raise an error for non TypeMap results" do
		res = @conn.exec( "SELECT 1" )
		expect{
			res.type_map = WrongTypeMapBuilder.new
		}.to raise_error(TypeError, /wrong return type.*Symbol/)
	end

	it "should raise an error when not subclassed for result" do
		res = @conn.exec( "SELECT 1" )
		expect{ res.map_types!(PG::TypeMap.new) }.to raise_error(NoMethodError, /fit_to_result/)
	end

	it "should raise an error when not subclassed for query params" do
		expect{
			@conn.exec_params( "SELECT $1", [5], 0, PG::TypeMap.new )
		}.to raise_error(NoMethodError, /fit_to_query/)
	end

	class TypeMapUsedForTypeCast < PG::TypeMap
		def fit_to_result(result)
			self
		end
		def fit_to_query(params)
			self
		end
	end

	it "should raise an error when used for param type casts" do
		expect{
			@conn.exec_params( "SELECT $1", [5], 0, TypeMapUsedForTypeCast.new )
		}.to raise_error(NotImplementedError, /not suitable to map query params/)
	end

	it "should raise an error when used for result type casts" do
		res = @conn.exec( "SELECT 1" )
		res.map_types!(TypeMapUsedForTypeCast.new)
		expect{ res.values }.to raise_error(NotImplementedError, /not suitable to map result values/)
	end
end

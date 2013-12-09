#!/usr/bin/env rspec
# encoding: utf-8

BEGIN {
	require 'pathname'

	basedir = Pathname( __FILE__ ).dirname.parent.parent
	libdir = basedir + 'lib'

	$LOAD_PATH.unshift( basedir.to_s ) unless $LOAD_PATH.include?( basedir.to_s )
	$LOAD_PATH.unshift( libdir.to_s ) unless $LOAD_PATH.include?( libdir.to_s )
}

require 'rspec'
require 'spec/lib/helpers'
require 'pg'

describe PG::ColumnMapping do

	before( :all ) do
		@conn = setup_testing_db( "PG_Result" )
	end

	before( :each ) do
		@conn.exec( 'BEGIN' )
	end

	after( :each ) do
		@conn.exec( 'ROLLBACK' )
	end

	after( :all ) do
		teardown_testing_db( @conn )
	end


	#
	# Examples
	#

	it "should do OID based type conversions", :ruby_19 do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, TRUE, '2013-06-30'::DATE, generate_series(4,5)" )
		res.map_types!.values.should == [
				[ 1, 'a', 2.0, true, Time.new('2013-06-30'), 4 ],
				[ 1, 'a', 2.0, true, Time.new('2013-06-30'), 5 ],
		]
	end

	it "should raise an error from default oid type conversion" do
		res = @conn.exec( "SELECT 'a'::CHAR(1)" )
		res.map_types!({}, PG::Type::NotDefined)
		expect{ res.values }.to raise_error(/no type decoder defined for OID 1042/)
	end

	it "should raise an error from decode method of type converter" do
		res = @conn.exec( "SELECT now()" )
		res.column_mapping = PG::ColumnMapping.new( [PG::Type::NotDefined] )
		expect{ res.values }.to raise_error(/no type decoder defined for OID 1184/)
	end

	class PG::Type::TestInvalidObj
	end

	it "should raise an error for invalid params" do
		expect{ PG::ColumnMapping.new( :WrongType ) }.to raise_error(TypeError, /wrong argument type/)
		expect{ PG::ColumnMapping.new( [:NonExistent] ) }.to raise_error(NameError, /uninitialized constant/)
		expect{ PG::ColumnMapping.new( [123] ) }.to raise_error(ArgumentError, /invalid/)
		expect{ PG::ColumnMapping.new( [:TestInvalidObj] ) }.to raise_error(TypeError, /wrong argument type/)
	end

	#
	# Examples text format
	#

	class TypePassThroughParameter
		def self.encode(value)
			value
		end
		def self.decode(*a)
			a
		end
	end

	it "should allow mixed type conversions" do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, '2013-06-30'::DATE, 3" )
		res.column_mapping = PG::ColumnMapping.new( [:TextInteger, :TextString, :TextFloat, TypePassThroughParameter, nil] )
		res.values.should == [[1, 'a', 2.0, [res, 0, 3, '2013-06-30'], '3' ]]
	end

	#
	# Examples text+binary format converters
	#

	it "should do boolean type conversions" do
		[1, 0].each do |format|
			res = @conn.exec( "SELECT true::BOOLEAN, false::BOOLEAN, NULL::BOOLEAN", [], format )
			res.map_types!
			res.values.should == [[true, false, nil]]
		end
	end

	it "should do binary type conversions" do
		[1, 0].each do |format|
			res = @conn.exec( "SELECT E'\\\\000\\\\377'::BYTEA", [], format )
			res.map_types!
			res.values.should == [[["00ff"].pack("H*")]]
			res.values[0][0].encoding.should == Encoding::ASCII_8BIT if Object.const_defined? :Encoding
		end
	end

	it "should do integer type conversions" do
		[1, 0].each do |format|
			res = @conn.exec( "SELECT -8999::INT2, -899999999::INT4, -8999999999999999999::INT8", [], format )
			res.map_types!
			res.values.should == [[-8999, -899999999, -8999999999999999999]]
		end
	end

	it "should do string type conversions" do
		@conn.internal_encoding = 'utf-8' if Object.const_defined? :Encoding
		[1, 0].each do |format|
			res = @conn.exec( "SELECT 'abcäöü'", [], format )
			res.map_types!
			res.values.should == [['abcäöü']]
			res.values[0][0].encoding.should == Encoding::UTF_8 if Object.const_defined? :Encoding
		end
	end

	it "should do float type conversions" do
		[1, 0].each do |format|
			res = @conn.exec( "SELECT -8.999e3::FLOAT4, 8.999e10::FLOAT4, -8999999999e-99::FLOAT8, NULL::FLOAT4", [], format )
			res.map_types!
			res.getvalue(0,0).should be_within(1e-2).of(-8.999e3)
			res.getvalue(0,1).should be_within(1e5).of(8.999e10)
			res.getvalue(0,2).should be_within(1e-109).of(-8999999999e-99)
			res.getvalue(0,3).should be_nil
		end
	end

end

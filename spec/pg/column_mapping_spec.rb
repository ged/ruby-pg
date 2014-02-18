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

module TypePassThroughParameter
	def self.encode(value)
		value
	end
	def self.decode(*a)
		a
	end
	def self.oid
		123456
	end
	def self.format
		1
	end
end

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


	it "should retrieve it's conversions" do
		cm = PG::ColumnMapping.new( [:INT4, :TEXT, :FLOAT4, TypePassThroughParameter, nil] )
		cm.types.should == [
			PG::Type::Text::INT4,
			PG::Type::Text::TEXT,
			PG::Type::Text::FLOAT4,
			TypePassThroughParameter,
			nil
		]
		cm.inspect.should == "#<PG::Type::CConverter INT4:0 TEXT:0 FLOAT4:0 TypePassThroughParameter:1 nil>"
	end

	it "should retrieve it's oids" do
		cm = PG::ColumnMapping.new( [:INT4, :TEXT, :FLOAT4, TypePassThroughParameter, nil] )
		cm.oids.should == [23, 25, 700, 123456, nil]
	end


	#
	# Encoding Examples
	#

	it "should do basic param encoding", :ruby_19 do
		res = @conn.exec_params( "SELECT $1,$2,$3,$4,$5 at time zone 'utc'",
			[1, "a", 2.1, true, Time.new(2013,6,30,14,58,59.3,"-02:00")], nil, PG::BasicTypeMapping )
		res.values.should == [
				[ "1", "a", "2.1", "t", "2013-06-30 16:58:59.3" ],
		]
	end

	#
	# Decoding Examples
	#

	it "should do OID based type conversions", :ruby_19 do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, TRUE, '2013-06-30'::DATE, generate_series(4,5)" )
		res.map_types!.values.should == [
				[ 1, 'a', 2.0, true, Time.new(2013,6,30), 4 ],
				[ 1, 'a', 2.0, true, Time.new(2013,6,30), 5 ],
		]
	end

	class Exception_in_column_mapping_for_result
		def self.column_mapping_for_result(result)
			raise "no mapping defined for result #{result.inspect}"
		end
	end

	it "should raise an error from default oid type conversion" do
		res = @conn.exec( "SELECT 1" )
		expect{
			res.map_types!(Exception_in_column_mapping_for_result)
		}.to raise_error(/no mapping defined/)
	end

	class WrongColumnMappingBuilder
		def self.column_mapping_for_result(result)
			:invalid_value
		end
	end

	it "should raise an error for non ColumnMapping results" do
		res = @conn.exec( "SELECT 1" )
		expect{
			res.column_mapping = WrongColumnMappingBuilder
		}.to raise_error(TypeError, /wrong argument type Symbol/)
	end

	class Exception_in_decode
		def self.column_mapping_for_result(result)
			types = result.nfields.times.map{ self }
			PG::ColumnMapping.new( types )
		end
		def self.decode(res, tuple, field)
			raise "no type decoder defined for tuple #{tuple} field #{field}"
		end
		def self.format
			0
		end
		def self.oid
			0
		end
	end

	it "should raise an error from decode method of type converter" do
		res = @conn.exec( "SELECT now()" )
		res.column_mapping = Exception_in_decode
		expect{ res.values }.to raise_error(/no type decoder defined/)
	end

	class PG::Type::Text::TestInvalidObj
	end

	it "should raise an error for invalid params" do
		expect{ PG::ColumnMapping.new( :WrongType ) }.to raise_error(TypeError, /wrong argument type/)
		expect{ PG::ColumnMapping.new( [:NonExistent] ) }.to raise_error(NameError, /uninitialized constant/)
		expect{ PG::ColumnMapping.new( [123] ) }.to raise_error(ArgumentError, /invalid/)
		expect{ PG::ColumnMapping.new( [:TestInvalidObj] ) }.to raise_error(ArgumentError, /invalid/)
	end

	#
	# Decoding Examples text format
	#

	it "should allow mixed type conversions" do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, '2013-06-30'::DATE, 3" )
		res.column_mapping = PG::ColumnMapping.new( [:INT4, :TEXT, :FLOAT4, TypePassThroughParameter, nil] )
		res.values.should == [[1, 'a', 2.0, ['2013-06-30', 0, 3], '3' ]]
	end

	#
	# Decoding Examples text+binary format converters
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
			res = @conn.exec( "SELECT 'abcäöü'::TEXT", [], format )
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

	it "should do datetime without time zone type conversions" do
		[0].each do |format|
			res = @conn.exec( "SELECT CAST('2013-12-31 23:58:59+02' AS TIMESTAMP WITHOUT TIME ZONE),
			                          CAST('2013-12-31 23:58:59.123-03' AS TIMESTAMP WITHOUT TIME ZONE)", [], format )
			res.map_types!
			res.getvalue(0,0).should == Time.new(2013, 12, 31, 23, 58, 59)
			res.getvalue(0,1).should == be_within(1e-3).of(Time.new(2013, 12, 31, 23, 58, 59.123))
		end
	end

	it "should do datetime with time zone type conversions" do
		[0].each do |format|
			res = @conn.exec( "SELECT CAST('2013-12-31 23:58:59+02' AS TIMESTAMP WITH TIME ZONE),
			                          CAST('2013-12-31 23:58:59.123-03' AS TIMESTAMP WITH TIME ZONE)", [], format )
			res.map_types!
			res.getvalue(0,0).should == Time.new(2013, 12, 31, 23, 58, 59, "+02:00")
			res.getvalue(0,1).should == be_within(1e-3).of(Time.new(2013, 12, 31, 23, 58, 59.123, "-03:00"))
		end
	end

	it "should do date type conversions" do
		[0].each do |format|
			res = @conn.exec( "SELECT CAST('2113-12-31' AS DATE),
			                          CAST('1913-12-31' AS DATE)", [], format )
			res.map_types!
			res.getvalue(0,0).should == Time.new(2113, 12, 31)
			res.getvalue(0,1).should == Time.new(1913, 12, 31)
		end
	end

	it "should do array type conversions" do
		[0].each do |format|
			res = @conn.exec( "SELECT CAST('{1,2,3}' AS INT2[]), CAST('{{1,2},{3,4}}' AS INT2[][]),
			                     CAST('{1,2,3}' AS INT4[]),
			                     CAST('{1,2,3}' AS INT8[]),
			                     CAST('{1,2,3}' AS TEXT[]),
			                     CAST('{1,2,3}' AS VARCHAR[]),
			                     CAST('{1,2,3}' AS FLOAT4[]),
			                     CAST('{1,2,3}' AS FLOAT8[])
			                  ", [], format )
			res.map_types!
			res.getvalue(0,0).should == [1,2,3]
			res.getvalue(0,1).should == [[1,2],[3,4]]
			res.getvalue(0,2).should == [1,2,3]
			res.getvalue(0,3).should == [1,2,3]
			res.getvalue(0,4).should == ['1','2','3']
			res.getvalue(0,5).should == ['1','2','3']
			res.getvalue(0,6).should == [1.0,2.0,3.0]
			res.getvalue(0,7).should == [1.0,2.0,3.0]
		end
	end

end

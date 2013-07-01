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

	OID_MAP_TEXT = {
		16 => PG::ColumnMapping::TextBoolean, # BOOLEAN
		23 => PG::ColumnMapping::TextInteger, # INTEGER
		701 => PG::ColumnMapping::TextFloat, # FLOAT
		705 => PG::ColumnMapping::TextString, # TEXT
		1082 => proc{|res, tuple, field, string| Time.new(string) }, # DATE
		1114 => proc{|res, tuple, field, string| Time.new(string) }, # TIMESTAMP WITHOUT TIME ZONE
		1184 => proc{|res, tuple, field, string| Time.new(string) }, # TIMESTAMP WITH TIME ZONE
	}

	it "should do OID based type conversions" do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, TRUE, '2013-06-30'::DATE, generate_series(4,5)" )
		types = res.nfields.times.map{|i| OID_MAP_TEXT[res.ftype(i)]}
		res.column_mapping = PG::ColumnMapping.new( *types )
		res.values.should == [[ 1, 'a', 2.0, true, Time.new('2013-06-30'), 4 ],
													[ 1, 'a', 2.0, true, Time.new('2013-06-30'), 5 ]]
	end

	it "should raise an error from proc type conversion" do
		res = @conn.exec( "SELECT now()" )
		res.column_mapping = PG::ColumnMapping.new( proc{ raise "foobar" } )
		expect{ res.values }.to raise_error(RuntimeError, /foobar/)
	end

	it "should raise an error for invalid params" do
		expect{ PG::ColumnMapping.new( :NonExistent ) }.to raise_error(NameError, /uninitialized constant/)
		expect{ PG::ColumnMapping.new( 123 ) }.to raise_error(ArgumentError, /invalid/)
		expect{ PG::ColumnMapping.new( :CConverter ) }.to raise_error(TypeError, /wrong argument type/)
	end

	#
	# Examples text format
	#

	it "should allow mixed type conversions" do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, '2013-06-30'::DATE, 3" )
		res.column_mapping = PG::ColumnMapping.new( :TextInteger, :TextString, :TextFloat, proc{|*a| a}, nil )
		res.values.should == [[1, 'a', 2.0, [res, 0, 3, '2013-06-30'], '3' ]]
	end

	it "should do bytea type conversions on text format" do
		res = @conn.exec( "SELECT '\\x00ff'::BYTEA" )
		res.column_mapping = PG::ColumnMapping.new( :TextBytea )
		res.values.should == [[["00ff"].pack("H*")]]
		res.values[0][0].encoding.should == Encoding::ASCII_8BIT
	end

	it "should do integer type conversions on text format" do
		res = @conn.exec( "SELECT 8999999999999999999::INT8" )
		res.column_mapping = PG::ColumnMapping.new( :TextInteger )
		res.values.should == [[8999999999999999999]]

		res = @conn.exec( "SELECT -8999999999999999999::INT8" )
		res.column_mapping = PG::ColumnMapping.new( :TextInteger )
		res.values.should == [[-8999999999999999999]]
	end

	#
	# Examples binary format
	#

	it "should do binary type conversions on binary format" do
		res = @conn.exec( "SELECT '\\x00ff'::BYTEA", [], 1 )
		res.column_mapping = PG::ColumnMapping.new( :BinaryBytea )
		res.values.should == [[["00ff"].pack("H*")]]
		res.values[0][0].encoding.should == Encoding::ASCII_8BIT
	end

	it "should do integer type conversions on binary format" do
		res = @conn.exec( "SELECT -8999::INT2", [], 1 )
		res.column_mapping = PG::ColumnMapping.new( :BinaryInteger )
		res.values.should == [[-8999]]

		res = @conn.exec( "SELECT -899999999::INT4", [], 1 )
		res.column_mapping = PG::ColumnMapping.new( :BinaryInteger )
		res.values.should == [[-899999999]]

		res = @conn.exec( "SELECT -8999999999999999999::INT8", [], 1 )
		res.column_mapping = PG::ColumnMapping.new( :BinaryInteger )
		res.values.should == [[-8999999999999999999]]
	end

	it "should do string type conversions on binary format" do
		@conn.internal_encoding = 'utf-8'
		res = @conn.exec( "SELECT 'abcäöü'", [], 1 )
		res.column_mapping = PG::ColumnMapping.new( :TextString )
		res.values.should == [['abcäöü']]
		res.values[0][0].encoding.should == Encoding::UTF_8
	end

end

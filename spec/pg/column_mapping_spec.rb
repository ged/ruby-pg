#!/usr/bin/env rspec
# encoding: utf-8

require_relative '../helpers'

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

	let!(:text_int_type) do
		PG::SimpleType.new encoder: PG::TextEncoder::INTEGER,
				decoder: PG::TextDecoder::INTEGER, name: 'INT4', oid: 23
	end
	let!(:text_float_type) do
		PG::SimpleType.new encoder: PG::TextEncoder::FLOAT,
				decoder: PG::TextDecoder::FLOAT, name: 'FLOAT4', oid: 700
	end
	let!(:text_string_type) do
		PG::SimpleType.new encoder: PG::TextEncoder::STRING,
				decoder: PG::TextDecoder::STRING, name: 'TEXT', oid: 25
	end
	let!(:text_bytea_type) do
		PG::SimpleType.new decoder: PG::TextDecoder::BYTEA, name: 'BYTEA', oid: 17
	end
	let!(:binary_bytea_type) do
		PG::SimpleType.new encoder: PG::BinaryEncoder::BYTEA,
				decoder: PG::BinaryDecoder::BYTEA, name: 'BYTEA', oid: 17, format: 1
	end
	let!(:pass_through_type) do
		type = PG::SimpleType.new encoder: proc{|v| v }, decoder: proc{|*v| v }
		type.oid = 123456
		type.format = 1
		type.name = 'pass_through'
		type
	end
	let!(:basic_type_mapping) do
		PG::BasicTypeMapping.new @conn
	end

	it "should retrieve it's conversions" do
		cm = PG::ColumnMapping.new( [text_int_type, text_string_type, text_float_type, pass_through_type, nil] )
		expect( cm.types ).to eq( [
			text_int_type,
			text_string_type,
			text_float_type,
			pass_through_type,
			nil
		] )
		expect( cm.inspect ).to eq( "#<PG::ColumnMapping INT4:0 TEXT:0 FLOAT4:0 pass_through:1 nil>" )
	end

	it "should retrieve it's oids" do
		cm = PG::ColumnMapping.new( [text_int_type, text_string_type, text_float_type, pass_through_type, nil] )
		expect( cm.oids ).to eq( [23, 25, 700, 123456, nil] )
	end


	#
	# Encoding Examples
	#

	it "should do basic param encoding", :ruby_19 do
		res = @conn.exec_params( "SELECT $1,$2,$3,$4,$5 at time zone 'utc'",
			[1, "a", 2.1, true, Time.new(2013,6,30,14,58,59.3,"-02:00")], nil, basic_type_mapping )

		expect( res.values ).to eq( [
				[ "1", "a", "2.1", "t", "2013-06-30 16:58:59.3" ],
		] )

		expect( result_typenames(res) ).to eq( ['bigint', 'text', 'double precision', 'boolean', 'timestamp without time zone'] )
	end

	it "should do array param encoding" do
		res = @conn.exec_params( "SELECT $1,$2,$3,$4", [
				[1, 2, 3], [[1, 2], [3, nil]],
				[1.11, 2.21],
				['/,"'.gsub("/", "\\"), nil, 'abcäöü'],
			], nil, basic_type_mapping )

		expect( res.values ).to eq( [[
				'{1,2,3}', '{{1,2},{3,NULL}}',
				'{1.11,2.21}',
				'{"//,/"",NULL,abcäöü}'.gsub("/", "\\"),
		]] )

		expect( result_typenames(res) ).to eq( ['bigint[]', 'bigint[]', 'double precision[]', 'text[]'] )
	end

	it "should encode integer params" do
		col_map = PG::ColumnMapping.new( [text_int_type]*3 )
		res = @conn.exec_params( "SELECT $1, $2, $3", [ 0, nil, "-999" ], 0, col_map )
		expect( res.values ).to eq( [
				[ "0", nil, "-999" ],
		] )
	end

	it "should encode bytea params" do
		data = "'\u001F\\"
		col_map = PG::ColumnMapping.new( [binary_bytea_type]*2 )
		res = @conn.exec_params( "SELECT $1, $2", [ data, nil ], 0, col_map )
		res.column_mapping = PG::ColumnMapping.new( [text_bytea_type]*2 )
		expect( res.values ).to eq( [
				[ data, nil ],
		] )
	end

	#
	# Decoding Examples
	#

	it "should do OID based type conversions", :ruby_19 do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, TRUE, '2013-06-30'::DATE, generate_series(4,5)" )
		expect( res.map_types!(basic_type_mapping).values ).to eq( [
				[ 1, 'a', 2.0, true, Time.new(2013,6,30), 4 ],
				[ 1, 'a', 2.0, true, Time.new(2013,6,30), 5 ],
		] )
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
			types = result.nfields.times.map{ PG::SimpleType.new decoder: self }
			PG::ColumnMapping.new( types )
		end
		def self.call(res, tuple, field)
			raise "no type decoder defined for tuple #{tuple} field #{field}"
		end
	end

	it "should raise an error from decode method of type converter" do
		res = @conn.exec( "SELECT now()" )
		res.column_mapping = Exception_in_decode
		expect{ res.values }.to raise_error(/no type decoder defined/)
	end

	it "should raise an error for invalid params" do
		expect{ PG::ColumnMapping.new( :WrongType ) }.to raise_error(TypeError, /wrong argument type/)
		expect{ PG::ColumnMapping.new( [123] ) }.to raise_error(ArgumentError, /invalid/)
	end

	#
	# Decoding Examples text format
	#

	it "should allow mixed type conversions" do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, '2013-06-30'::DATE, 3" )
		res.column_mapping = PG::ColumnMapping.new( [text_int_type, text_string_type, text_float_type, pass_through_type, nil] )
		expect( res.values ).to eq( [[1, 'a', 2.0, ['2013-06-30', 0, 3], '3' ]] )
	end

	#
	# Decoding Examples text+binary format converters
	#

	describe "connection wide type mapping" do
		before :each do
			@conn.type_mapping = basic_type_mapping
		end

		after :each do
			@conn.type_mapping = nil
		end

		it "should do boolean type conversions" do
			[1, 0].each do |format|
				res = @conn.exec( "SELECT true::BOOLEAN, false::BOOLEAN, NULL::BOOLEAN", [], format )
				expect( res.values ).to eq( [[true, false, nil]] )
			end
		end

		it "should do binary type conversions" do
			[1, 0].each do |format|
				res = @conn.exec( "SELECT E'\\\\000\\\\377'::BYTEA", [], format )
				expect( res.values ).to eq( [[["00ff"].pack("H*")]] )
				expect( res.values[0][0].encoding ).to eq( Encoding::ASCII_8BIT ) if Object.const_defined? :Encoding
			end
		end

		it "should do integer type conversions" do
			[1, 0].each do |format|
				res = @conn.exec( "SELECT -8999::INT2, -899999999::INT4, -8999999999999999999::INT8", [], format )
				expect( res.values ).to eq( [[-8999, -899999999, -8999999999999999999]] )
			end
		end

		it "should do string type conversions" do
			@conn.internal_encoding = 'utf-8' if Object.const_defined? :Encoding
			[1, 0].each do |format|
				res = @conn.exec( "SELECT 'abcäöü'::TEXT", [], format )
				expect( res.values ).to eq( [['abcäöü']] )
				expect( res.values[0][0].encoding ).to eq( Encoding::UTF_8 ) if Object.const_defined? :Encoding
			end
		end

		it "should do float type conversions" do
			[1, 0].each do |format|
				res = @conn.exec( "SELECT -8.999e3::FLOAT4,
				                  8.999e10::FLOAT4,
				                  -8999999999e-99::FLOAT8,
				                  NULL::FLOAT4,
				                  'NaN'::FLOAT4,
				                  'Infinity'::FLOAT4,
				                  '-Infinity'::FLOAT4
				                ", [], format )
				expect( res.getvalue(0,0) ).to be_within(1e-2).of(-8.999e3)
				expect( res.getvalue(0,1) ).to be_within(1e5).of(8.999e10)
				expect( res.getvalue(0,2) ).to be_within(1e-109).of(-8999999999e-99)
				expect( res.getvalue(0,3) ).to be_nil
				expect( res.getvalue(0,4) ).to be_nan
				expect( res.getvalue(0,5) ).to eq( Float::INFINITY )
				expect( res.getvalue(0,6) ).to eq( -Float::INFINITY )
			end
		end

		it "should do datetime without time zone type conversions" do
			[0].each do |format|
				res = @conn.exec( "SELECT CAST('2013-12-31 23:58:59+02' AS TIMESTAMP WITHOUT TIME ZONE),
																	CAST('2013-12-31 23:58:59.123-03' AS TIMESTAMP WITHOUT TIME ZONE)", [], format )
				expect( res.getvalue(0,0) ).to eq( Time.new(2013, 12, 31, 23, 58, 59) )
				expect( res.getvalue(0,1) ).to be_within(1e-3).of(Time.new(2013, 12, 31, 23, 58, 59.123))
			end
		end

		it "should do datetime with time zone type conversions" do
			[0].each do |format|
				res = @conn.exec( "SELECT CAST('2013-12-31 23:58:59+02' AS TIMESTAMP WITH TIME ZONE),
																	CAST('2013-12-31 23:58:59.123-03' AS TIMESTAMP WITH TIME ZONE)", [], format )
				expect( res.getvalue(0,0) ).to eq( Time.new(2013, 12, 31, 23, 58, 59, "+02:00") )
				expect( res.getvalue(0,1) ).to be_within(1e-3).of(Time.new(2013, 12, 31, 23, 58, 59.123, "-03:00"))
			end
		end

		it "should do date type conversions" do
			[0].each do |format|
				res = @conn.exec( "SELECT CAST('2113-12-31' AS DATE),
																	CAST('1913-12-31' AS DATE)", [], format )
				expect( res.getvalue(0,0) ).to eq( Time.new(2113, 12, 31) )
				expect( res.getvalue(0,1) ).to eq( Time.new(1913, 12, 31) )
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
				expect( res.getvalue(0,0) ).to eq( [1,2,3] )
				expect( res.getvalue(0,1) ).to eq( [[1,2],[3,4]] )
				expect( res.getvalue(0,2) ).to eq( [1,2,3] )
				expect( res.getvalue(0,3) ).to eq( [1,2,3] )
				expect( res.getvalue(0,4) ).to eq( ['1','2','3'] )
				expect( res.getvalue(0,5) ).to eq( ['1','2','3'] )
				expect( res.getvalue(0,6) ).to eq( [1.0,2.0,3.0] )
				expect( res.getvalue(0,7) ).to eq( [1.0,2.0,3.0] )
			end
		end
	end

end

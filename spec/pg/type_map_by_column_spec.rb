#!/usr/bin/env rspec
# encoding: utf-8

require_relative '../helpers'

require 'pg'


describe PG::TypeMapByColumn do

	let!(:textenc_int){ PG::TextEncoder::Integer.new name: 'INT4', oid: 23 }
	let!(:textdec_int){ PG::TextDecoder::Integer.new name: 'INT4', oid: 23 }
	let!(:textenc_float){ PG::TextEncoder::Float.new name: 'FLOAT4', oid: 700 }
	let!(:textdec_float){ PG::TextDecoder::Float.new name: 'FLOAT4', oid: 700 }
	let!(:textenc_string){ PG::TextEncoder::String.new name: 'TEXT', oid: 25 }
	let!(:textdec_string){ PG::TextDecoder::String.new name: 'TEXT', oid: 25 }
	let!(:textdec_bytea){ PG::TextDecoder::Bytea.new name: 'BYTEA', oid: 17 }
	let!(:binaryenc_bytea){ PG::BinaryEncoder::Bytea.new name: 'BYTEA', oid: 17, format: 1 }
	let!(:binarydec_bytea){ PG::BinaryDecoder::Bytea.new name: 'BYTEA', oid: 17, format: 1 }
	let!(:pass_through_type) do
		type = Class.new(PG::SimpleDecoder) do
			def decode(*v)
				v
			end
		end.new
		type.oid = 123456
		type.format = 1
		type.name = 'pass_through'
		type
	end

	it "should retrieve it's conversions" do
		cm = PG::TypeMapByColumn.new( [textdec_int, textenc_string, textdec_float, pass_through_type, nil] )
		expect( cm.coders ).to eq( [
			textdec_int,
			textenc_string,
			textdec_float,
			pass_through_type,
			nil
		] )
		expect( cm.inspect ).to eq( "#<PG::TypeMapByColumn INT4:0 TEXT:0 FLOAT4:0 pass_through:1 nil>" )
	end

	it "should retrieve it's oids" do
		cm = PG::TypeMapByColumn.new( [textdec_int, textdec_string, textdec_float, pass_through_type, nil] )
		expect( cm.oids ).to eq( [23, 25, 700, 123456, nil] )
	end

	it "should gracefully handle not initialized state" do
		# PG::TypeMapByColumn is not initialized in allocate function, like other
		# type maps, but in #initialize. So it might be not called by derived classes.

		not_init = Class.new(PG::TypeMapByColumn) do
			def initialize
				# no super call
			end
		end.new

		expect{ @conn.exec_params( "SELECT $1", [ 0 ], 0, not_init ) }.to raise_error(NotImplementedError)

		res = @conn.exec( "SELECT 1" )
		expect{ res.type_map = not_init }.to raise_error(NotImplementedError)

		@conn.copy_data("COPY (SELECT 1) TO STDOUT") do
			decoder = PG::TextDecoder::CopyRow.new(type_map: not_init)
			expect{ @conn.get_copy_data(false, decoder) }.to raise_error(NotImplementedError)
			@conn.get_copy_data
		end
	end


	#
	# Encoding Examples
	#

	it "should encode integer params" do
		col_map = PG::TypeMapByColumn.new( [textenc_int]*3 )
		res = @conn.exec_params( "SELECT $1, $2, $3", [ 0, nil, "-999" ], 0, col_map )
		expect( res.values ).to eq( [
				[ "0", nil, "-999" ],
		] )
	end

	it "should encode bytea params" do
		data = "'\u001F\\"
		col_map = PG::TypeMapByColumn.new( [binaryenc_bytea]*2 )
		res = @conn.exec_params( "SELECT $1, $2", [ data, nil ], 0, col_map )
		res.type_map = PG::TypeMapByColumn.new( [textdec_bytea]*2 )
		expect( res.values ).to eq( [
				[ data, nil ],
		] )
	end


	it "should allow hash form parameters for default encoder" do
		col_map = PG::TypeMapByColumn.new( [nil, nil] )
		hash_param_bin = { value: ["00ff"].pack("H*"), type: 17, format: 1 }
		hash_param_nil = { value: nil, type: 17, format: 1 }
		res = @conn.exec_params( "SELECT $1, $2",
					[ hash_param_bin, hash_param_nil ], 0, col_map )
		expect( res.values ).to eq( [["\\x00ff", nil]] )
		expect( result_typenames(res) ).to eq( ['bytea', 'bytea'] )
	end

	it "should convert hash form parameters to string when using string encoders" do
		col_map = PG::TypeMapByColumn.new( [textenc_string, textenc_string] )
		hash_param_bin = { value: ["00ff"].pack("H*"), type: 17, format: 1 }
		hash_param_nil = { value: nil, type: 17, format: 1 }
		res = @conn.exec_params( "SELECT $1::text, $2::text",
					[ hash_param_bin, hash_param_nil ], 0, col_map )
		expect( res.values ).to eq( [["{:value=>\"\\x00\\xFF\", :type=>17, :format=>1}", "{:value=>nil, :type=>17, :format=>1}"]] )
	end

	it "shouldn't allow param mappings with different number of fields" do
		expect{
			@conn.exec_params( "SELECT $1", [ 123 ], 0, PG::TypeMapByColumn.new([]) )
		}.to raise_error(ArgumentError, /mapped columns/)
	end

	#
	# Decoding Examples
	#

	class Exception_in_decode < PG::SimpleDecoder
		def decode(res, tuple, field)
			raise "no type decoder defined for tuple #{tuple} field #{field}"
		end
	end

	it "should raise an error from decode method of type converter" do
		res = @conn.exec( "SELECT now()" )
		types = Array.new( res.nfields, Exception_in_decode.new )
		res.type_map = PG::TypeMapByColumn.new( types )
		expect{ res.values }.to raise_error(/no type decoder defined/)
	end

	it "should raise an error for invalid params" do
		expect{ PG::TypeMapByColumn.new( :WrongType ) }.to raise_error(TypeError, /wrong argument type/)
		expect{ PG::TypeMapByColumn.new( [123] ) }.to raise_error(ArgumentError, /invalid/)
	end

	it "shouldn't allow result mappings with different number of fields" do
		res = @conn.exec( "SELECT 1" )
		expect{ res.type_map = PG::TypeMapByColumn.new([]) }.to raise_error(ArgumentError, /mapped columns/)
	end

	#
	# Decoding Examples text format
	#

	it "should allow mixed type conversions" do
		res = @conn.exec( "SELECT 1, 'a', 2.0::FLOAT, '2013-06-30'::DATE, 3" )
		res.type_map = PG::TypeMapByColumn.new( [textdec_int, textdec_string, textdec_float, pass_through_type, nil] )
		expect( res.values ).to eq( [[1, 'a', 2.0, ['2013-06-30', 0, 3], '3' ]] )
	end

end

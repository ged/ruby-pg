#!/usr/bin/env rspec
# encoding: utf-8

require 'pg'


describe "PG::Type derivations" do
	let!(:textenc_int) { PG::TextEncoder::Integer.new name: 'Integer', oid: 23 }
	let!(:textdec_int) { PG::TextDecoder::Integer.new name: 'Integer', oid: 23 }
	let!(:textenc_float) { PG::TextEncoder::Float.new }
	let!(:textdec_float) { PG::TextDecoder::Float.new }
	let!(:textenc_string) { PG::TextEncoder::String.new }
	let!(:textdec_string) { PG::TextDecoder::String.new }
	let!(:textenc_timestamp) { PG::TextEncoder::TimestampWithoutTimeZone.new }
	let!(:textdec_timestamp) { PG::TextDecoder::TimestampWithoutTimeZone.new }
	let!(:binaryenc_int2) { PG::BinaryEncoder::Int2.new }
	let!(:binaryenc_int4) { PG::BinaryEncoder::Int4.new }
	let!(:binaryenc_int8) { PG::BinaryEncoder::Int8.new }
	let!(:binarydec_integer) { PG::BinaryDecoder::Integer.new }

	let!(:intenc_incrementer) do
		Class.new(PG::SimpleEncoder) do
			def encode(value)
				(value+1).to_s
			end
		end.new
	end
	let!(:intdec_incrementer) do
		Class.new(PG::SimpleDecoder) do
			def decode(string, tuple=nil, field=nil)
				string.to_i+1
			end
		end.new
	end

	let!(:intenc_incrementer_with_int_result) do
		Class.new(PG::SimpleEncoder) do
			def encode(value)
				value.to_i+1
			end
		end.new
	end

	it "shouldn't be possible to build a PG::Type directly" do
		expect{ PG::Coder.new }.to raise_error(TypeError, /cannot/)
	end

	describe PG::SimpleCoder do
		describe '#decode' do
			it "should offer decode method with tuple/field" do
				res = textdec_int.decode("123", 1, 1)
				expect( res ).to eq( 123 )
			end

			it "should offer decode method without tuple/field" do
				res = textdec_int.decode("234")
				expect( res ).to eq( 234 )
			end

			it "should decode with ruby decoder" do
				expect( intdec_incrementer.decode("3") ).to eq( 4 )
			end

			it "should raise when decode method is called with wrong args" do
				expect{ textdec_int.decode() }.to raise_error(ArgumentError)
				expect{ textdec_int.decode("123", 2, 3, 4) }.to raise_error(ArgumentError)
				expect{ textdec_int.decode(2, 3, 4) }.to raise_error(TypeError)
				expect( intdec_incrementer.decode(2, 3, 4) ).to eq( 3 )
			end
		end

		describe '#encode' do
			it "should offer encode method for text type" do
				res = textenc_int.encode(123)
				expect( res ).to eq( "123" )
			end

			it "should offer encode method for binary type" do
				res = binaryenc_int8.encode(123)
				expect( res ).to eq( [123].pack("q>") )
			end

			it "should encode integers from string to binary format" do
				expect( binaryenc_int2.encode("  -123  ") ).to eq( [-123].pack("s>") )
				expect( binaryenc_int4.encode("  -123  ") ).to eq( [-123].pack("l>") )
				expect( binaryenc_int8.encode("  -123  ") ).to eq( [-123].pack("q>") )
				expect( binaryenc_int2.encode("  123-xyz  ") ).to eq( [123].pack("s>") )
				expect( binaryenc_int4.encode("  123-xyz  ") ).to eq( [123].pack("l>") )
				expect( binaryenc_int8.encode("  123-xyz  ") ).to eq( [123].pack("q>") )
			end

			it "should encode integers of different length to text format" do
				expect( textenc_int.encode(0) ).to eq( "0" )
				30.times do |zeros|
					expect( textenc_int.encode(10 ** zeros) ).to eq( "1" + "0"*zeros )
					expect( textenc_int.encode(-10 ** zeros) ).to eq( "-1" + "0"*zeros )
				end
			end

			it "should encode integers from string to text format" do
				expect( textenc_int.encode("  -123  ") ).to eq( "-123" )
				expect( textenc_int.encode("  123-xyz  ") ).to eq( "123" )
			end

			it "should encode with ruby encoder" do
				expect( intenc_incrementer.encode(3) ).to eq( "4" )
			end

			it "should return when ruby encoder returns non string values" do
				expect( intenc_incrementer_with_int_result.encode(3) ).to eq( 4 )
			end
		end

		it "should be possible to marshal encoders" do
			mt = Marshal.dump(textenc_int)
			lt = Marshal.load(mt)
			expect( lt.to_h ).to eq( textenc_int.to_h )
		end

		it "should be possible to marshal decoders" do
			mt = Marshal.dump(textdec_int)
			lt = Marshal.load(mt)
			expect( lt.to_h ).to eq( textdec_int.to_h )
		end

		it "should respond to to_h" do
			expect( textenc_int.to_h ).to eq( {
				name: 'Integer', oid: 23, format: 0
			} )
		end

		it "should have reasonable default values" do
			t = PG::TextEncoder::String.new
			expect( t.format ).to eq( 0 )
			expect( t.oid ).to eq( 0 )
			expect( t.name ).to be_nil
		end
	end

	describe PG::CompositeCoder do
		describe "Array types" do
			let!(:textenc_string_array) { PG::TextEncoder::Array.new elements_type: textenc_string }
			let!(:textdec_string_array) { PG::TextDecoder::Array.new elements_type: textdec_string }
			let!(:textenc_int_array) { PG::TextEncoder::Array.new elements_type: textenc_int, needs_quotation: false }
			let!(:textdec_int_array) { PG::TextDecoder::Array.new elements_type: textdec_int, needs_quotation: false }
			let!(:textenc_float_array) { PG::TextEncoder::Array.new elements_type: textenc_float, needs_quotation: false }
			let!(:textdec_float_array) { PG::TextDecoder::Array.new elements_type: textdec_float, needs_quotation: false }
			let!(:textenc_timestamp_array) { PG::TextEncoder::Array.new elements_type: textenc_timestamp, needs_quotation: false }
			let!(:textdec_timestamp_array) { PG::TextDecoder::Array.new elements_type: textdec_timestamp, needs_quotation: false }
			let!(:textenc_string_array_with_delimiter) { PG::TextEncoder::Array.new elements_type: textenc_string, delimiter: ';' }
			let!(:textdec_string_array_with_delimiter) { PG::TextDecoder::Array.new elements_type: textdec_string, delimiter: ';' }

			#
			# Array parser specs are thankfully borrowed from here:
			# https://github.com/dockyard/pg_array_parser
			#
			describe '#decode' do
				context 'one dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							expect( textdec_string_array.decode(%[{}]) ).to eq( [] )
						end
					end

					context 'no strings' do
						it 'returns an array of strings' do
							expect( textdec_string_array.decode(%[{1,2,3}]) ).to eq( ['1','2','3'] )
						end
					end

					context 'NULL values' do
						it 'returns an array of strings, with nils replacing NULL characters' do
							expect( textdec_string_array.decode(%[{1,NULL,NULL}]) ).to eq( ['1',nil,nil] )
						end
					end

					context 'quoted NULL' do
						it 'returns an array with the word NULL' do
							expect( textdec_string_array.decode(%[{1,"NULL",3}]) ).to eq( ['1','NULL','3'] )
						end
					end

					context 'strings' do
						it 'returns an array of strings when containing commas in a quoted string' do
							expect( textdec_string_array.decode(%[{1,"2,3",4}]) ).to eq( ['1','2,3','4'] )
						end

						it 'returns an array of strings when containing an escaped quote' do
							expect( textdec_string_array.decode(%[{1,"2\\",3",4}]) ).to eq( ['1','2",3','4'] )
						end

						it 'returns an array of strings when containing an escaped backslash' do
							expect( textdec_string_array.decode(%[{1,"2\\\\",3,4}]) ).to eq( ['1','2\\','3','4'] )
							expect( textdec_string_array.decode(%[{1,"2\\\\\\",3",4}]) ).to eq( ['1','2\\",3','4'] )
						end

						it 'returns an array containing empty strings' do
							expect( textdec_string_array.decode(%[{1,"",3,""}]) ).to eq( ['1', '', '3', ''] )
						end

						it 'returns an array containing unicode strings' do
							expect( textdec_string_array.decode(%[{"Paragraph 399(b)(i) – “valid leave” – meaning"}]) ).to eq(['Paragraph 399(b)(i) – “valid leave” – meaning'])
						end

						it 'respects a different delimiter' do
							expect( textdec_string_array_with_delimiter.decode(%[{1;2;3}]) ).to eq( ['1','2','3'] )
						end
					end
				end

				context 'two dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							expect( textdec_string_array.decode(%[{{}}]) ).to eq( [[]] )
							expect( textdec_string_array.decode(%[{{},{}}]) ).to eq( [[],[]] )
						end
					end
					context 'no strings' do
						it 'returns an array of strings with a sub array' do
							expect( textdec_string_array.decode(%[{1,{2,3},4}]) ).to eq( ['1',['2','3'],'4'] )
						end
					end
					context 'strings' do
						it 'returns an array of strings with a sub array' do
							expect( textdec_string_array.decode(%[{1,{"2,3"},4}]) ).to eq( ['1',['2,3'],'4'] )
						end
						it 'returns an array of strings with a sub array and a quoted }' do
							expect( textdec_string_array.decode(%[{1,{"2,}3",NULL},4}]) ).to eq( ['1',['2,}3',nil],'4'] )
						end
						it 'returns an array of strings with a sub array and a quoted {' do
							expect( textdec_string_array.decode(%[{1,{"2,{3"},4}]) ).to eq( ['1',['2,{3'],'4'] )
						end
						it 'returns an array of strings with a sub array and a quoted { and escaped quote' do
							expect( textdec_string_array.decode(%[{1,{"2\\",{3"},4}]) ).to eq( ['1',['2",{3'],'4'] )
						end
						it 'returns an array of strings with a sub array with empty strings' do
							expect( textdec_string_array.decode(%[{1,{""},4,{""}}]) ).to eq( ['1',[''],'4',['']] )
						end
					end
					context 'timestamps' do
						it 'decodes an array of timestamps with sub arrays' do
							expect( textdec_timestamp_array.decode('{2014-12-31 00:00:00,{NULL,2016-01-02 23:23:59.0000000}}') ).
								to eq( [Time.new(2014,12,31),[nil, Time.new(2016,01,02, 23, 23, 59)]] )
						end
					end
				end
				context 'three dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							expect( textdec_string_array.decode(%[{{{}}}]) ).to eq( [[[]]] )
							expect( textdec_string_array.decode(%[{{{},{}},{{},{}}}]) ).to eq( [[[],[]],[[],[]]] )
						end
					end
					it 'returns an array of strings with sub arrays' do
						expect( textdec_string_array.decode(%[{1,{2,{3,4}},{NULL,6},7}]) ).to eq( ['1',['2',['3','4']],[nil,'6'],'7'] )
					end
				end

				it 'should decode array of types with decoder in ruby space' do
					array_type = PG::TextDecoder::Array.new elements_type: intdec_incrementer
					expect( array_type.decode(%[{3,4}]) ).to eq( [4,5] )
				end

				it 'should decode array of nil types' do
					array_type = PG::TextDecoder::Array.new elements_type: nil
					expect( array_type.decode(%[{3,4}]) ).to eq( ['3','4'] )
				end

				context 'identifier quotation' do
					it 'should build an array out of an quoted identifier string' do
						quoted_type = PG::TextDecoder::Identifier.new elements_type: textdec_string
						expect( quoted_type.decode(%["A.".".B"]) ).to eq( ["A.", ".B"] )
						expect( quoted_type.decode(%["'A"".""B'"]) ).to eq( ['\'A"."B\''] )
					end

					it 'should split unquoted identifier string' do
						quoted_type = PG::TextDecoder::Identifier.new elements_type: textdec_string
						expect( quoted_type.decode(%[a.b]) ).to eq( ['a','b'] )
						expect( quoted_type.decode(%[a]) ).to eq( ['a'] )
					end
				end
			end

			describe '#encode' do
				context 'three dimensional arrays' do
					it 'encodes an array of strings and numbers with sub arrays' do
						expect( textenc_string_array.encode(['1',['2',['3','4']],[nil,6],7.8]) ).to eq( %[{"1",{"2",{"3","4"}},{NULL,"6"},"7.8"}] )
					end
					it 'encodes an array of int8 with sub arrays' do
						expect( textenc_int_array.encode([1,[2,[3,4]],[nil,6],7]) ).to eq( %[{1,{2,{3,4}},{NULL,6},7}] )
					end
					it 'encodes an array of int8 with strings' do
						expect( textenc_int_array.encode(['1',['2'],'3']) ).to eq( %[{1,{2},3}] )
					end
					it 'encodes an array of float8 with sub arrays' do
						expect( textenc_float_array.encode([1000.11,[-0.00221,[3.31,-441]],[nil,6.61],-7.71]) ).to match(Regexp.new(%[^{1.0001*E+03,{-2.2*E-03,{3.3*E+00,-4.4*E+02}},{NULL,6.6*E+00},-7.7*E+00}$].gsub(/([\.\+\{\}\,])/, "\\\\\\1").gsub(/\*/, "\\d*")))
					end
				end
				context 'two dimensional arrays' do
					it 'encodes an array of timestamps with sub arrays' do
						expect( textenc_timestamp_array.encode([Time.new(2014,12,31),[nil, Time.new(2016,01,02, 23, 23, 59.99)]]) ).
								to eq( %[{2014-12-31 00:00:00.000000000,{NULL,2016-01-02 23:23:59.990000000}}] )
					end
				end
				context 'one dimensional array' do
					it 'can encode empty arrays' do
						expect( textenc_int_array.encode([]) ).to eq( '{}' )
						expect( textenc_string_array.encode([]) ).to eq( '{}' )
					end
					it 'respects a different delimiter' do
						expect( textenc_string_array_with_delimiter.encode(['a','b','c']) ).to eq( '{"a";"b";"c"}' )
					end
				end

				context 'array of types with encoder in ruby space' do
					it 'encodes with quotation' do
						array_type = PG::TextEncoder::Array.new elements_type: intenc_incrementer, needs_quotation: true
						expect( array_type.encode([3,4]) ).to eq( %[{"4","5"}] )
					end

					it 'encodes without quotation' do
						array_type = PG::TextEncoder::Array.new elements_type: intenc_incrementer, needs_quotation: false
						expect( array_type.encode([3,4]) ).to eq( %[{4,5}] )
					end

					it "should raise when ruby encoder returns non string values" do
						array_type = PG::TextEncoder::Array.new elements_type: intenc_incrementer_with_int_result, needs_quotation: false
						expect{ array_type.encode([3,4]) }.to raise_error(TypeError)
					end
				end

				context 'identifier quotation' do
					it 'should quote and escape identifier' do
						quoted_type = PG::TextEncoder::Identifier.new elements_type: textenc_string
						expect( quoted_type.encode(['schema','table','col']) ).to eq( %["schema"."table"."col"] )
						expect( quoted_type.encode(['A.','.B']) ).to eq( %["A.".".B"] )
						expect( quoted_type.encode(%['A"."B']) ).to eq( %["'A"".""B'"] )
					end

					it 'shouldn\'t quote or escape identifier if requested to not do' do
						quoted_type = PG::TextEncoder::Identifier.new elements_type: textenc_string,
								needs_quotation: false
						expect( quoted_type.encode(['a','b']) ).to eq( %[a.b] )
						expect( quoted_type.encode(%[a.b]) ).to eq( %[a.b] )
					end
				end

				context 'literal quotation' do
					it 'should quote and escape literals' do
						quoted_type = PG::TextEncoder::QuotedLiteral.new elements_type: textenc_string_array
						expect( quoted_type.encode(["'A\",","\\B'"]) ).to eq( %['{"''A\\",","\\\\B''"}'] )
					end
				end
			end

			it "should be possible to marshal encoders" do
				mt = Marshal.dump(textenc_int_array)
				lt = Marshal.load(mt)
				expect( lt.to_h ).to eq( textenc_int_array.to_h )
			end

			it "should be possible to marshal encoders" do
				mt = Marshal.dump(textdec_int_array)
				lt = Marshal.load(mt)
				expect( lt.to_h ).to eq( textdec_int_array.to_h )
			end

			it "should respond to to_h" do
				expect( textenc_int_array.to_h ).to eq( {
					name: nil, oid: 0, format: 0,
					elements_type: textenc_int, needs_quotation: false, delimiter: ','
				} )
			end

			it "shouldn't accept invalid elements_types" do
				expect{ PG::TextEncoder::Array.new elements_type: false }.to raise_error(TypeError)
			end

			it "should have reasonable default values" do
				t = PG::TextEncoder::Array.new
				expect( t.format ).to eq( 0 )
				expect( t.oid ).to eq( 0 )
				expect( t.name ).to be_nil
				expect( t.needs_quotation? ).to eq( true )
				expect( t.delimiter ).to eq( ',' )
				expect( t.elements_type ).to be_nil
			end
		end
	end
end

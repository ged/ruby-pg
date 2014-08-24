#!/usr/bin/env rspec
# encoding: utf-8

require_relative '../helpers'

require 'pg'


describe "PG::Type derivations" do
	let!(:text_int_type) { PG::SimpleType.new encoder: PG::TextEncoder::INTEGER, decoder: PG::TextDecoder::INTEGER, name: 'Integer', oid: 23 }
	let!(:text_float_type) { PG::SimpleType.new encoder: PG::TextEncoder::FLOAT, decoder: PG::TextDecoder::FLOAT }
	let!(:text_string_type) { PG::SimpleType.new encoder: PG::TextEncoder::STRING, decoder: PG::TextDecoder::STRING }
	let!(:text_timestamp_type) { PG::SimpleType.new encoder: PG::TextEncoder::TIMESTAMP_WITHOUT_TIME_ZONE, decoder: PG::TextDecoder::TIMESTAMP_WITHOUT_TIME_ZONE }
	let!(:binary_int2_type) { PG::SimpleType.new encoder: PG::BinaryEncoder::INT2, decoder: PG::BinaryDecoder::INTEGER }
	let!(:binary_int4_type) { PG::SimpleType.new encoder: PG::BinaryEncoder::INT4, decoder: PG::BinaryDecoder::INTEGER }
	let!(:binary_int8_type) { PG::SimpleType.new encoder: PG::BinaryEncoder::INT8, decoder: PG::BinaryDecoder::INTEGER }

	it "shouldn't be possible to build a PG::Type directly" do
		expect{ PG::Type.new }.to raise_error(TypeError, /cannot/)
	end

	describe PG::SimpleType do
		describe '#decode' do
			it "should offer decode method with tuple/field" do
				res = text_int_type.decode("123", 1, 1)
				expect( res ).to eq( 123 )
			end

			it "should offer decode method without tuple/field" do
				res = text_int_type.decode("234")
				expect( res ).to eq( 234 )
			end

			it "should decode with ruby decoder" do
				ruby_type = PG::SimpleType.new decoder: proc{|v| v.to_i+1 }
				expect( ruby_type.decode("3") ).to eq( 4 )
			end

			it "should raise when decode method is called with wrong args" do
				expect{ text_int_type.decode() }.to raise_error(ArgumentError)
				expect{ text_int_type.decode("123", 2, 3, 4) }.to raise_error(ArgumentError)
				expect{ text_int_type.decode(2, 3, 4) }.to raise_error(TypeError)
				ruby_type = PG::SimpleType.new decoder: proc{|v| v.to_i+1 }
				expect{ ruby_type.decode(2, 3, 4) }.to raise_error(TypeError)
			end
		end

		describe '#encode' do
			it "should offer encode method for text type" do
				res = text_int_type.encode(123)
				expect( res ).to eq( "123" )
			end

			it "should offer encode method for binary type" do
				res = binary_int8_type.encode(123)
				expect( res ).to eq( [123].pack("q>") )
			end

			it "should encode integers from string to binary format" do
				expect( binary_int2_type.encode("  -123  ") ).to eq( [-123].pack("s>") )
				expect( binary_int4_type.encode("  -123  ") ).to eq( [-123].pack("l>") )
				expect( binary_int8_type.encode("  -123  ") ).to eq( [-123].pack("q>") )
				expect( binary_int2_type.encode("  123-xyz  ") ).to eq( [123].pack("s>") )
				expect( binary_int4_type.encode("  123-xyz  ") ).to eq( [123].pack("l>") )
				expect( binary_int8_type.encode("  123-xyz  ") ).to eq( [123].pack("q>") )
			end

			it "should encode integers of different length to text format" do
				expect( text_int_type.encode(0) ).to eq( "0" )
				30.times do |zeros|
					expect( text_int_type.encode(10 ** zeros) ).to eq( "1" + "0"*zeros )
					expect( text_int_type.encode(-10 ** zeros) ).to eq( "-1" + "0"*zeros )
				end
			end

			it "should encode integers from string to text format" do
				expect( text_int_type.encode("  -123  ") ).to eq( "-123" )
				expect( text_int_type.encode("  123-xyz  ") ).to eq( "123" )
			end

			it "should encode with ruby encoder" do
				ruby_type = PG::SimpleType.new encoder: proc{|v| (v+1).to_s }
				expect( ruby_type.encode(3) ).to eq( "4" )
			end

			it "should raise when ruby encoder returns non string values" do
				ruby_type = PG::SimpleType.new encoder: proc{|v| v+1 }
				expect{ ruby_type.encode(3) }.to raise_error(TypeError)
			end
		end

		it "should be possible to marshal types" do
			mt = Marshal.dump(text_int_type)
			lt = Marshal.load(mt)
			expect( lt.to_h ).to eq( text_int_type.to_h )
		end

		it "should respond to to_h" do
			expect( text_int_type.to_h ).to eq( {
				encoder: PG::TextEncoder::INTEGER, decoder: PG::TextDecoder::INTEGER, name: 'Integer', oid: 23, format: 0
			} )
		end

		it "shouldn't accept invalid coders" do
			expect{ PG::SimpleType.new encoder: PG::TextDecoder::INTEGER }.to raise_error(TypeError)
			expect{ PG::SimpleType.new encoder: PG::TextEncoder::ARRAY }.to raise_error(TypeError)
			expect{ PG::SimpleType.new decoder: PG::TextDecoder::ARRAY }.to raise_error(TypeError)
			expect{ PG::SimpleType.new decoder: PG::TextEncoder::INTEGER }.to raise_error(TypeError)
			expect{ PG::SimpleType.new encoder: false }.to raise_error(TypeError)
			expect{ PG::SimpleType.new decoder: false }.to raise_error(TypeError)
		end

		it "should have reasonable default values" do
			t = described_class.new
			expect( t.encoder ).to be_nil
			expect( t.decoder ).to be_nil
			expect( t.format ).to eq( 0 )
			expect( t.oid ).to eq( 0 )
			expect( t.name ).to be_nil
		end
	end

	describe PG::CompositeType do
		describe "Array types" do
			let!(:text_string_array_type) { PG::CompositeType.new encoder: PG::TextEncoder::ARRAY, decoder: PG::TextDecoder::ARRAY, elements_type: text_string_type }
			let!(:text_int_array_type) { PG::CompositeType.new encoder: PG::TextEncoder::ARRAY, decoder: PG::TextDecoder::ARRAY, elements_type: text_int_type, needs_quotation: false }
			let!(:text_float_array_type) { PG::CompositeType.new encoder: PG::TextEncoder::ARRAY, decoder: PG::TextDecoder::ARRAY, elements_type: text_float_type, needs_quotation: false }
			let!(:text_timestamp_array_type) { PG::CompositeType.new encoder: PG::TextEncoder::ARRAY, decoder: PG::TextDecoder::ARRAY, elements_type: text_timestamp_type, needs_quotation: false }

			#
			# Array parser specs are thankfully borrowed from here:
			# https://github.com/dockyard/pg_array_parser
			#
			describe '#decode' do
				context 'one dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							expect( text_string_array_type.decode(%[{}]) ).to eq( [] )
						end
					end

					context 'no strings' do
						it 'returns an array of strings' do
							expect( text_string_array_type.decode(%[{1,2,3}]) ).to eq( ['1','2','3'] )
						end
					end

					context 'NULL values' do
						it 'returns an array of strings, with nils replacing NULL characters' do
							expect( text_string_array_type.decode(%[{1,NULL,NULL}]) ).to eq( ['1',nil,nil] )
						end
					end

					context 'quoted NULL' do
						it 'returns an array with the word NULL' do
							expect( text_string_array_type.decode(%[{1,"NULL",3}]) ).to eq( ['1','NULL','3'] )
						end
					end

					context 'strings' do
						it 'returns an array of strings when containing commas in a quoted string' do
							expect( text_string_array_type.decode(%[{1,"2,3",4}]) ).to eq( ['1','2,3','4'] )
						end

						it 'returns an array of strings when containing an escaped quote' do
							expect( text_string_array_type.decode(%[{1,"2\\",3",4}]) ).to eq( ['1','2",3','4'] )
						end

						it 'returns an array of strings when containing an escaped backslash' do
							expect( text_string_array_type.decode(%[{1,"2\\\\",3,4}]) ).to eq( ['1','2\\','3','4'] )
							expect( text_string_array_type.decode(%[{1,"2\\\\\\",3",4}]) ).to eq( ['1','2\\",3','4'] )
						end

						it 'returns an array containing empty strings' do
							expect( text_string_array_type.decode(%[{1,"",3,""}]) ).to eq( ['1', '', '3', ''] )
						end

						it 'returns an array containing unicode strings' do
							expect( text_string_array_type.decode(%[{"Paragraph 399(b)(i) – “valid leave” – meaning"}]) ).to eq(['Paragraph 399(b)(i) – “valid leave” – meaning'])
						end
					end
				end

				context 'two dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							expect( text_string_array_type.decode(%[{{}}]) ).to eq( [[]] )
							expect( text_string_array_type.decode(%[{{},{}}]) ).to eq( [[],[]] )
						end
					end
					context 'no strings' do
						it 'returns an array of strings with a sub array' do
							expect( text_string_array_type.decode(%[{1,{2,3},4}]) ).to eq( ['1',['2','3'],'4'] )
						end
					end
					context 'strings' do
						it 'returns an array of strings with a sub array' do
							expect( text_string_array_type.decode(%[{1,{"2,3"},4}]) ).to eq( ['1',['2,3'],'4'] )
						end
						it 'returns an array of strings with a sub array and a quoted }' do
							expect( text_string_array_type.decode(%[{1,{"2,}3",NULL},4}]) ).to eq( ['1',['2,}3',nil],'4'] )
						end
						it 'returns an array of strings with a sub array and a quoted {' do
							expect( text_string_array_type.decode(%[{1,{"2,{3"},4}]) ).to eq( ['1',['2,{3'],'4'] )
						end
						it 'returns an array of strings with a sub array and a quoted { and escaped quote' do
							expect( text_string_array_type.decode(%[{1,{"2\\",{3"},4}]) ).to eq( ['1',['2",{3'],'4'] )
						end
						it 'returns an array of strings with a sub array with empty strings' do
							expect( text_string_array_type.decode(%[{1,{""},4,{""}}]) ).to eq( ['1',[''],'4',['']] )
						end
					end
					context 'timestamps' do
						it 'decodes an array of timestamps with sub arrays' do
							expect( text_timestamp_array_type.decode('{2014-12-31 00:00:00,{NULL,2016-01-02 23:23:59.0000000}}') ).
								to eq( [Time.new(2014,12,31),[nil, Time.new(2016,01,02, 23, 23, 59)]] )
						end
					end
				end
				context 'three dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							expect( text_string_array_type.decode(%[{{{}}}]) ).to eq( [[[]]] )
							expect( text_string_array_type.decode(%[{{{},{}},{{},{}}}]) ).to eq( [[[],[]],[[],[]]] )
						end
					end
					it 'returns an array of strings with sub arrays' do
						expect( text_string_array_type.decode(%[{1,{2,{3,4}},{NULL,6},7}]) ).to eq( ['1',['2',['3','4']],[nil,'6'],'7'] )
					end
				end

				it 'should decode array of types with decoder in ruby space' do
					ruby_type = PG::SimpleType.new decoder: proc{|v| v.to_i+1 }
					array_type = PG::CompositeType.new decoder: PG::TextDecoder::ARRAY, elements_type: ruby_type
					expect( array_type.decode(%[{3,4}]) ).to eq( [4,5] )
				end

				it 'should decode array of nil types' do
					array_type = PG::CompositeType.new decoder: PG::TextDecoder::ARRAY, elements_type: nil
					expect( array_type.decode(%[{3,4}]) ).to eq( ['3','4'] )
				end

				context 'identifier quotation' do
					it 'should build an array out of an quoted identifier string' do
						quoted_type = PG::CompositeType.new decoder: PG::TextDecoder::IDENTIFIER, elements_type: text_string_type
						expect( quoted_type.decode(%["A.".".B"]) ).to eq( ["A.", ".B"] )
						expect( quoted_type.decode(%["'A"".""B'"]) ).to eq( ['\'A"."B\''] )
					end

					it 'should split unquoted identifier string' do
						quoted_type = PG::CompositeType.new decoder: PG::TextDecoder::IDENTIFIER, elements_type: text_string_type
						expect( quoted_type.decode(%[a.b]) ).to eq( ['a','b'] )
						expect( quoted_type.decode(%[a]) ).to eq( ['a'] )
					end
				end
			end

			describe '#encode' do
				context 'three dimensional arrays' do
					it 'encodes an array of strings and numbers with sub arrays' do
						expect( text_string_array_type.encode(['1',['2',['3','4']],[nil,6],7.8]) ).to eq( %[{"1",{"2",{"3","4"}},{NULL,"6"},"7.8"}] )
					end
					it 'encodes an array of int8 with sub arrays' do
						expect( text_int_array_type.encode([1,[2,[3,4]],[nil,6],7]) ).to eq( %[{1,{2,{3,4}},{NULL,6},7}] )
					end
					it 'encodes an array of int8 with strings' do
						expect( text_int_array_type.encode(['1',['2'],'3']) ).to eq( %[{1,{2},3}] )
					end
					it 'encodes an array of float8 with sub arrays' do
						expect( text_float_array_type.encode([1000.11,[-0.00221,[3.31,-441]],[nil,6.61],-7.71]) ).to match(Regexp.new(%[^{1.0001*E+03,{-2.2*E-03,{3.3*E+00,-4.4*E+02}},{NULL,6.6*E+00},-7.7*E+00}$].gsub(/([\.\+\{\}\,])/, "\\\\\\1").gsub(/\*/, "\\d*")))
					end
				end
				context 'two dimensional arrays' do
					it 'encodes an array of timestamps with sub arrays' do
						expect( text_timestamp_array_type.encode([Time.new(2014,12,31),[nil, Time.new(2016,01,02, 23, 23, 59.99)]]) ).
								to eq( %[{2014-12-31 00:00:00.000000000,{NULL,2016-01-02 23:23:59.990000000}}] )
					end
				end
				context 'one dimensional array' do
					it 'can encode empty arrays' do
						expect( text_int_array_type.encode([]) ).to eq( '{}' )
						expect( text_string_array_type.encode([]) ).to eq( '{}' )
					end
				end

				context 'array of types with encoder in ruby space' do
					it 'encodes with quotation' do
						ruby_type = PG::SimpleType.new encoder: proc{|v| (v+1).to_s }
						array_type = PG::CompositeType.new encoder: PG::TextEncoder::ARRAY, elements_type: ruby_type, needs_quotation: true
						expect( array_type.encode([3,4]) ).to eq( %[{"4","5"}] )
					end

					it 'encodes without quotation' do
						ruby_type = PG::SimpleType.new encoder: proc{|v| (v+1).to_s }
						array_type = PG::CompositeType.new encoder: PG::TextEncoder::ARRAY, elements_type: ruby_type, needs_quotation: false
						expect( array_type.encode([3,4]) ).to eq( %[{4,5}] )
					end

					it "should raise when ruby encoder returns non string values" do
						ruby_type = PG::SimpleType.new encoder: proc{|v| v+1 }
						array_type = PG::CompositeType.new encoder: PG::TextEncoder::ARRAY, elements_type: ruby_type, needs_quotation: false
						expect{ array_type.encode([3,4]) }.to raise_error(TypeError)
					end
				end

				context 'identifier quotation' do
					it 'should quote and escape identifier' do
						quoted_type = PG::CompositeType.new encoder: PG::TextEncoder::IDENTIFIER, elements_type: text_string_type
						expect( quoted_type.encode(['A.','.B']) ).to eq( %["A.".".B"] )
						expect( quoted_type.encode(%['A"."B']) ).to eq( %["'A"".""B'"] )
					end

					it 'shouldn\'t quote or escape identifier if requested to not do' do
						quoted_type = PG::CompositeType.new encoder: PG::TextEncoder::IDENTIFIER, elements_type: text_string_type,
								needs_quotation: false
						expect( quoted_type.encode(['a','b']) ).to eq( %[a.b] )
						expect( quoted_type.encode(%[a.b]) ).to eq( %[a.b] )
					end
				end

				context 'literal quotation' do
					it 'should quote and escape literals' do
						quoted_type = PG::CompositeType.new encoder: PG::TextEncoder::QUOTED_LITERAL, elements_type: text_string_array_type
						expect( quoted_type.encode(["'A\",","\\B'"]) ).to eq( %['{"''A\\",","\\\\B''"}'] )
					end
				end
			end

			it "should be possible to marshal types" do
				mt = Marshal.dump(text_int_array_type)
				lt = Marshal.load(mt)
				expect( lt.to_h ).to eq( text_int_array_type.to_h )
			end

			it "should respond to to_h" do
				expect( text_int_array_type.to_h ).to eq( {
					encoder: PG::TextEncoder::ARRAY, decoder: PG::TextDecoder::ARRAY, name: nil, oid: 0, format: 0,
					elements_type: text_int_type, needs_quotation: false
				} )
			end

			it "shouldn't accept invalid coders" do
				expect{ PG::CompositeType.new encoder: PG::TextDecoder::ARRAY }.to raise_error(TypeError)
				expect{ PG::CompositeType.new encoder: PG::TextEncoder::INTEGER }.to raise_error(TypeError)
				expect{ PG::CompositeType.new decoder: PG::TextDecoder::INTEGER }.to raise_error(TypeError)
				expect{ PG::CompositeType.new decoder: PG::TextEncoder::ARRAY }.to raise_error(TypeError)
				expect{ PG::CompositeType.new encoder: false }.to raise_error(TypeError)
				expect{ PG::CompositeType.new decoder: false }.to raise_error(TypeError)
			end

			it "shouldn't accept invalid elements_types" do
				expect{ PG::CompositeType.new elements_type: false }.to raise_error(TypeError)
			end

			it "should have reasonable default values" do
				t = described_class.new
				expect( t.encoder ).to be_nil
				expect( t.decoder ).to be_nil
				expect( t.format ).to eq( 0 )
				expect( t.oid ).to eq( 0 )
				expect( t.name ).to be_nil
				expect( t.needs_quotation? ).to eq( true )
				expect( t.elements_type ).to be_nil
			end
		end
	end
end

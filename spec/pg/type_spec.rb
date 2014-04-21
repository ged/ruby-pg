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

describe "PG::Type derivations" do
	let!(:text_int_type) { PG::SimpleType.new encoder: PG::TextEncoder::Integer, decoder: PG::TextDecoder::Integer, name: 'Integer', oid: 23 }
	let!(:text_float_type) { PG::SimpleType.new encoder: PG::TextEncoder::Float, decoder: PG::TextDecoder::Float }
	let!(:text_string_type) { PG::SimpleType.new encoder: PG::TextEncoder::String, decoder: PG::TextDecoder::String }
	let!(:text_timestamp_type) { PG::SimpleType.new encoder: PG::TextEncoder::TimestampWithoutTimeZone, decoder: PG::TextDecoder::TimestampWithoutTimeZone }
	let!(:binary_int8_type) { PG::SimpleType.new encoder: PG::BinaryEncoder::Int8, decoder: PG::BinaryDecoder::Integer }

	it "shouldn't be possible to build a PG::Type directly" do
		expect{ PG::Type.new }.to raise_error(TypeError, /cannot/)
	end

	describe PG::SimpleType do
		describe '#decode' do
			it "should offer decode method with tuple/field" do
				res = text_int_type.decode("123", 1, 1)
				res.should == 123
			end

			it "should offer decode method without tuple/field" do
				res = text_int_type.decode("234")
				res.should == 234
			end

			it "should decode with ruby decoder" do
				ruby_type = PG::SimpleType.new decoder: proc{|v| v.to_i+1 }
				ruby_type.decode("3").should eq 4
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
				res.should == "123"
			end

			it "should offer encode method for binary type" do
				res = binary_int8_type.encode(123)
				res.should == [123].pack("q>")
			end

			it "should encode integers of different length to text format" do
				text_int_type.encode(0).should == "0"
				30.times do |zeros|
					text_int_type.encode(10 ** zeros).should == "1" + "0"*zeros
					text_int_type.encode(-10 ** zeros).should == "-1" + "0"*zeros
				end
			end

			it "should encode with ruby encoder" do
				ruby_type = PG::SimpleType.new encoder: proc{|v| (v+1).to_s }
				ruby_type.encode(3).should eq "4"
			end

			it "should raise when ruby encoder returns non string values" do
				ruby_type = PG::SimpleType.new encoder: proc{|v| v+1 }
				expect{ ruby_type.encode(3) }.to raise_error(TypeError)
			end
		end

		it "should be possible to marshal types" do
			mt = Marshal.dump(text_int_type)
			lt = Marshal.load(mt)
			lt.to_h.should == text_int_type.to_h
		end

		it "should respond to to_h" do
			text_int_type.to_h.should == {
				encoder: PG::TextEncoder::Integer, decoder: PG::TextDecoder::Integer, name: 'Integer', oid: 23, format: 0
			}
		end

		it "shouldn't accept invalid coders" do
			expect{ PG::SimpleType.new encoder: PG::TextDecoder::Integer }.to raise_error(TypeError)
			expect{ PG::SimpleType.new encoder: PG::TextEncoder::Array }.to raise_error(TypeError)
			expect{ PG::SimpleType.new decoder: PG::TextDecoder::Array }.to raise_error(TypeError)
			expect{ PG::SimpleType.new decoder: PG::TextEncoder::Integer }.to raise_error(TypeError)
			expect{ PG::SimpleType.new encoder: false }.to raise_error(TypeError)
			expect{ PG::SimpleType.new decoder: false }.to raise_error(TypeError)
		end

		it "should have reasonable default values" do
			t = described_class.new
			t.encoder.should be_nil
			t.decoder.should be_nil
			t.format.should == 0
			t.oid.should == 0
			t.name.should be_nil
		end
	end

	describe PG::CompositeType do
		describe "Array types" do
			let!(:text_string_array_type) { PG::CompositeType.new encoder: PG::TextEncoder::Array, decoder: PG::TextDecoder::Array, elements_type: text_string_type }
			let!(:text_int_array_type) { PG::CompositeType.new encoder: PG::TextEncoder::Array, decoder: PG::TextDecoder::Array, elements_type: text_int_type, needs_quotation: false }
			let!(:text_float_array_type) { PG::CompositeType.new encoder: PG::TextEncoder::Array, decoder: PG::TextDecoder::Array, elements_type: text_float_type, needs_quotation: false }
			let!(:text_timestamp_array_type) { PG::CompositeType.new encoder: PG::TextEncoder::Array, decoder: PG::TextDecoder::Array, elements_type: text_timestamp_type, needs_quotation: false }

			#
			# Array parser specs are thankfully borrowed from here:
			# https://github.com/dockyard/pg_array_parser
			#
			describe '#decode' do
				context 'one dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							text_string_array_type.decode(%[{}]).should eq []
						end
					end

					context 'no strings' do
						it 'returns an array of strings' do
							text_string_array_type.decode(%[{1,2,3}]).should eq ['1','2','3']
						end
					end

					context 'NULL values' do
						it 'returns an array of strings, with nils replacing NULL characters' do
							text_string_array_type.decode(%[{1,NULL,NULL}]).should eq ['1',nil,nil]
						end
					end

					context 'quoted NULL' do
						it 'returns an array with the word NULL' do
							text_string_array_type.decode(%[{1,"NULL",3}]).should eq ['1','NULL','3']
						end
					end

					context 'strings' do
						it 'returns an array of strings when containing commas in a quoted string' do
							text_string_array_type.decode(%[{1,"2,3",4}]).should eq ['1','2,3','4']
						end

						it 'returns an array of strings when containing an escaped quote' do
							text_string_array_type.decode(%[{1,"2\\",3",4}]).should eq ['1','2",3','4']
						end

						it 'returns an array of strings when containing an escaped backslash' do
							text_string_array_type.decode(%[{1,"2\\\\",3,4}]).should eq ['1','2\\','3','4']
							text_string_array_type.decode(%[{1,"2\\\\\\",3",4}]).should eq ['1','2\\",3','4']
						end

						it 'returns an array containing empty strings' do
							text_string_array_type.decode(%[{1,"",3,""}]).should eq ['1', '', '3', '']
						end

						it 'returns an array containing unicode strings' do
							text_string_array_type.decode(%[{"Paragraph 399(b)(i) – “valid leave” – meaning"}]).should eq(['Paragraph 399(b)(i) – “valid leave” – meaning'])
						end
					end
				end

				context 'two dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							text_string_array_type.decode(%[{{}}]).should eq [[]]
							text_string_array_type.decode(%[{{},{}}]).should eq [[],[]]
						end
					end
					context 'no strings' do
						it 'returns an array of strings with a sub array' do
							text_string_array_type.decode(%[{1,{2,3},4}]).should eq ['1',['2','3'],'4']
						end
					end
					context 'strings' do
						it 'returns an array of strings with a sub array' do
							text_string_array_type.decode(%[{1,{"2,3"},4}]).should eq ['1',['2,3'],'4']
						end
						it 'returns an array of strings with a sub array and a quoted }' do
							text_string_array_type.decode(%[{1,{"2,}3",NULL},4}]).should eq ['1',['2,}3',nil],'4']
						end
						it 'returns an array of strings with a sub array and a quoted {' do
							text_string_array_type.decode(%[{1,{"2,{3"},4}]).should eq ['1',['2,{3'],'4']
						end
						it 'returns an array of strings with a sub array and a quoted { and escaped quote' do
							text_string_array_type.decode(%[{1,{"2\\",{3"},4}]).should eq ['1',['2",{3'],'4']
						end
						it 'returns an array of strings with a sub array with empty strings' do
							text_string_array_type.decode(%[{1,{""},4,{""}}]).should eq ['1',[''],'4',['']]
						end
					end
					context 'timestamps' do
						it 'decodes an array of timestamps with sub arrays' do
							text_timestamp_array_type.decode('{2014-12-31 00:00:00,{NULL,2016-01-02 23:23:59.0000000}}').
								should eq [Time.new(2014,12,31),[nil, Time.new(2016,01,02, 23, 23, 59)]]
						end
					end
				end
				context 'three dimensional arrays' do
					context 'empty' do
						it 'returns an empty array' do
							text_string_array_type.decode(%[{{{}}}]).should eq [[[]]]
							text_string_array_type.decode(%[{{{},{}},{{},{}}}]).should eq [[[],[]],[[],[]]]
						end
					end
					it 'returns an array of strings with sub arrays' do
						text_string_array_type.decode(%[{1,{2,{3,4}},{NULL,6},7}]).should eq ['1',['2',['3','4']],[nil,'6'],'7']
					end
				end

				it 'should decode array of types with decoder in ruby space' do
					ruby_type = PG::SimpleType.new decoder: proc{|v| v.to_i+1 }
					array_type = PG::CompositeType.new decoder: PG::TextDecoder::Array, elements_type: ruby_type
					array_type.decode(%[{3,4}]).should eq [4,5]
				end

				it 'should decode array of nil types' do
					array_type = PG::CompositeType.new decoder: PG::TextDecoder::Array, elements_type: nil
					array_type.decode(%[{3,4}]).should eq ['3','4']
				end

				context 'identifier quotation' do
					it 'should build an array out of an quoted identifier string' do
						quoted_type = PG::CompositeType.new decoder: PG::TextDecoder::Identifier, elements_type: text_string_type
						quoted_type.decode(%["A.".".B"]).should eq ["A.", ".B"]
						quoted_type.decode(%["'A"".""B'"]).should eq ['\'A"."B\'']
					end

					it 'should split unquoted identifier string' do
						quoted_type = PG::CompositeType.new decoder: PG::TextDecoder::Identifier, elements_type: text_string_type
						quoted_type.decode(%[a.b]).should eq ['a','b']
						quoted_type.decode(%[a]).should eq ['a']
					end
				end
			end

			describe '#encode' do
				context 'three dimensional arrays' do
					it 'encodes an array of strings and numbers with sub arrays' do
						text_string_array_type.encode(['1',['2',['3','4']],[nil,6],7.8]).should eq %[{"1",{"2",{"3","4"}},{NULL,"6"},"7.8"}]
					end
					it 'encodes an array of int8 with sub arrays' do
						text_int_array_type.encode([1,[2,[3,4]],[nil,6],7]).should eq %[{1,{2,{3,4}},{NULL,6},7}]
					end
					it 'encodes an array of float8 with sub arrays' do
						text_float_array_type.encode([1000.11,[-0.00221,[3.31,-441]],[nil,6.61],-7.71]).should match Regexp.new(%[^{1.0001*E+03,{-2.2*E-03,{3.3*E+00,-4.4*E+02}},{NULL,6.6*E+00},-7.7*E+00}$].gsub(/([\.\+\{\}\,])/, "\\\\\\1").gsub(/\*/, "\\d*"))
					end
				end
				context 'two dimensional arrays' do
					it 'encodes an array of timestamps with sub arrays' do
						text_timestamp_array_type.encode([Time.new(2014,12,31),[nil, Time.new(2016,01,02, 23, 23, 59.99)]]).
								should eq %[{2014-12-31 00:00:00.000000000,{NULL,2016-01-02 23:23:59.990000000}}]
					end
				end


				context 'array of types with encoder in ruby space' do
					it 'encodes with quotation' do
						ruby_type = PG::SimpleType.new encoder: proc{|v| (v+1).to_s }
						array_type = PG::CompositeType.new encoder: PG::TextEncoder::Array, elements_type: ruby_type, needs_quotation: true
						array_type.encode([3,4]).should eq %[{"4","5"}]
					end

					it 'encodes without quotation' do
						ruby_type = PG::SimpleType.new encoder: proc{|v| (v+1).to_s }
						array_type = PG::CompositeType.new encoder: PG::TextEncoder::Array, elements_type: ruby_type, needs_quotation: false
						array_type.encode([3,4]).should eq %[{4,5}]
					end

					it "should raise when ruby encoder returns non string values" do
						ruby_type = PG::SimpleType.new encoder: proc{|v| v+1 }
						array_type = PG::CompositeType.new encoder: PG::TextEncoder::Array, elements_type: ruby_type, needs_quotation: false
						expect{ array_type.encode([3,4]) }.to raise_error(TypeError)
					end
				end

				context 'identifier quotation' do
					it 'should quote and escape identifier' do
						quoted_type = PG::CompositeType.new encoder: PG::TextEncoder::Identifier, elements_type: text_string_type
						quoted_type.encode(['A.','.B']).should eq %["A.".".B"]
						quoted_type.encode(%['A"."B']).should eq %["'A"".""B'"]
					end

					it 'shouldn\'t quote or escape identifier if requested to not do' do
						quoted_type = PG::CompositeType.new encoder: PG::TextEncoder::Identifier, elements_type: text_string_type,
								needs_quotation: false
						quoted_type.encode(['a','b']).should eq %[a.b]
						quoted_type.encode(%[a.b]).should eq %[a.b]
					end
				end
			end

			it "should be possible to marshal types" do
				mt = Marshal.dump(text_int_array_type)
				lt = Marshal.load(mt)
				lt.to_h.should == text_int_array_type.to_h
			end

			it "should respond to to_h" do
				text_int_array_type.to_h.should == {
					encoder: PG::TextEncoder::Array, decoder: PG::TextDecoder::Array, name: nil, oid: 0, format: 0,
					elements_type: text_int_type, needs_quotation: false
				}
			end

			it "shouldn't accept invalid coders" do
				expect{ PG::CompositeType.new encoder: PG::TextDecoder::Array }.to raise_error(TypeError)
				expect{ PG::CompositeType.new encoder: PG::TextEncoder::Integer }.to raise_error(TypeError)
				expect{ PG::CompositeType.new decoder: PG::TextDecoder::Integer }.to raise_error(TypeError)
				expect{ PG::CompositeType.new decoder: PG::TextEncoder::Array }.to raise_error(TypeError)
				expect{ PG::CompositeType.new encoder: false }.to raise_error(TypeError)
				expect{ PG::CompositeType.new decoder: false }.to raise_error(TypeError)
			end

			it "shouldn't accept invalid elements_types" do
				expect{ PG::CompositeType.new elements_type: false }.to raise_error(TypeError)
			end

			it "should have reasonable default values" do
				t = described_class.new
				t.encoder.should be_nil
				t.decoder.should be_nil
				t.format.should == 0
				t.oid.should == 0
				t.name.should be_nil
				t.needs_quotation?.should be true
				t.elements_type.should be_nil
			end
		end
	end
end

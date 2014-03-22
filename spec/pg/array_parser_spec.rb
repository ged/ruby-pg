# -*- coding: utf-8 -*-
require 'pg'

#
# Array parser specs are thankfully borrowed from here:
# https://github.com/dockyard/pg_array_parser
#
describe 'PG::Type::Text::TEXTARRAY' do
	let!(:text_array_type) { PG::Type::Text::TEXTARRAY }
	let!(:int8_array_type) { PG::Type::Text::INT8ARRAY }
	let!(:float8_array_type) { PG::Type::Text::FLOAT8ARRAY }

	describe '#decode' do
		context 'one dimensional arrays' do
			context 'empty' do
				it 'returns an empty array' do
					text_array_type.decode(%[{}]).should eq []
				end
			end

			context 'no strings' do
				it 'returns an array of strings' do
					text_array_type.decode(%[{1,2,3}]).should eq ['1','2','3']
				end
			end

			context 'NULL values' do
				it 'returns an array of strings, with nils replacing NULL characters' do
					text_array_type.decode(%[{1,NULL,NULL}]).should eq ['1',nil,nil]
				end
			end

			context 'quoted NULL' do
				it 'returns an array with the word NULL' do
					text_array_type.decode(%[{1,"NULL",3}]).should eq ['1','NULL','3']
				end
			end

			context 'strings' do
				it 'returns an array of strings when containing commas in a quoted string' do
					text_array_type.decode(%[{1,"2,3",4}]).should eq ['1','2,3','4']
				end

				it 'returns an array of strings when containing an escaped quote' do
					text_array_type.decode(%[{1,"2\\",3",4}]).should eq ['1','2",3','4']
				end

				it 'returns an array of strings when containing an escaped backslash' do
					text_array_type.decode(%[{1,"2\\\\",3,4}]).should eq ['1','2\\','3','4']
					text_array_type.decode(%[{1,"2\\\\\\",3",4}]).should eq ['1','2\\",3','4']
				end

				it 'returns an array containing empty strings' do
					text_array_type.decode(%[{1,"",3,""}]).should eq ['1', '', '3', '']
				end

				it 'returns an array containing unicode strings' do
					text_array_type.decode(%[{"Paragraph 399(b)(i) – “valid leave” – meaning"}]).should eq(['Paragraph 399(b)(i) – “valid leave” – meaning'])
				end
			end
		end

		context 'two dimensional arrays' do
			context 'empty' do
				it 'returns an empty array' do
					text_array_type.decode(%[{{}}]).should eq [[]]
					text_array_type.decode(%[{{},{}}]).should eq [[],[]]
				end
			end
			context 'no strings' do
				it 'returns an array of strings with a sub array' do
					text_array_type.decode(%[{1,{2,3},4}]).should eq ['1',['2','3'],'4']
				end
			end
			context 'strings' do
				it 'returns an array of strings with a sub array' do
					text_array_type.decode(%[{1,{"2,3"},4}]).should eq ['1',['2,3'],'4']
				end
				it 'returns an array of strings with a sub array and a quoted }' do
					text_array_type.decode(%[{1,{"2,}3",NULL},4}]).should eq ['1',['2,}3',nil],'4']
				end
				it 'returns an array of strings with a sub array and a quoted {' do
					text_array_type.decode(%[{1,{"2,{3"},4}]).should eq ['1',['2,{3'],'4']
				end
				it 'returns an array of strings with a sub array and a quoted { and escaped quote' do
					text_array_type.decode(%[{1,{"2\\",{3"},4}]).should eq ['1',['2",{3'],'4']
				end
				it 'returns an array of strings with a sub array with empty strings' do
					text_array_type.decode(%[{1,{""},4,{""}}]).should eq ['1',[''],'4',['']]
				end
			end
		end
		context 'three dimensional arrays' do
			context 'empty' do
				it 'returns an empty array' do
					text_array_type.decode(%[{{{}}}]).should eq [[[]]]
					text_array_type.decode(%[{{{},{}},{{},{}}}]).should eq [[[],[]],[[],[]]]
				end
			end
			it 'returns an array of strings with sub arrays' do
				text_array_type.decode(%[{1,{2,{3,4}},{NULL,6},7}]).should eq ['1',['2',['3','4']],[nil,'6'],'7']
			end
		end
	end

	describe '#encode' do
		context 'three dimensional arrays' do
			it 'encodes an array of strings and numbers with sub arrays' do
				text_array_type.encode(['1',['2',['3','4']],[nil,6],7.8]).should eq %[{"1",{"2",{"3","4"}},{NULL,"6"},"7.8"}]
			end
			it 'encodes an array of int8 with sub arrays' do
				int8_array_type.encode([1,[2,[3,4]],[nil,6],7]).should eq %[{1,{2,{3,4}},{NULL,6},7}]
			end
			it 'encodes an array of float8 with sub arrays' do
				float8_array_type.encode([1000.11,[-0.00221,[3.31,-441]],[nil,6.61],-7.71]).should match Regexp.new(%[^{1.0001*E+03,{-2.2*E-03,{3.3*E+00,-4.4*E+02}},{NULL,6.6*E+00},-7.7*E+00}$].gsub(/([\.\+\{\}\,])/, "\\\\\\1").gsub(/\*/, "\\d*"))
			end
		end
	end
end

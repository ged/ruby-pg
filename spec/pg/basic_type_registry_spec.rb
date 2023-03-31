# -*- rspec -*-
# encoding: utf-8

require_relative '../helpers'

describe 'Basic type mapping' do
	describe PG::BasicTypeRegistry do
		it "should be shareable for Ractor", :ractor do
			Ractor.make_shareable(PG::BasicTypeRegistry.new.register_default_types)
		end

		it "can register_type" do
			regi = PG::BasicTypeRegistry.new
			res = regi.register_type(1, 'int4', PG::BinaryEncoder::Int8, PG::BinaryDecoder::Integer)

			expect( res ).to be( regi )
			expect( regi.coders_for(1, :encoder)['int4'] ).to be_kind_of(PG::BinaryEncoder::Int8)
			expect( regi.coders_for(1, :decoder)['int4'] ).to be_kind_of(PG::BinaryDecoder::Integer)
		end

		it "can alias_type" do
			regi = PG::BasicTypeRegistry.new
			regi.register_type(1, 'int4', PG::BinaryEncoder::Int4, PG::BinaryDecoder::Integer)
			res = regi.alias_type(1, 'int8', 'int4')

			expect( res ).to be( regi )
			expect( regi.coders_for(1, :encoder)['int8'] ).to be_kind_of(PG::BinaryEncoder::Int4)
			expect( regi.coders_for(1, :decoder)['int8'] ).to be_kind_of(PG::BinaryDecoder::Integer)
		end

		it "can register_default_types" do
			regi = PG::BasicTypeRegistry.new
			res = regi.register_default_types

			expect( res ).to be( regi )
			expect( regi.coders_for(0, :encoder)['float8'] ).to be_kind_of(PG::TextEncoder::Float)
			expect( regi.coders_for(0, :decoder)['float8'] ).to be_kind_of(PG::TextDecoder::Float)
		end

		it "can define_default_types (alias to register_default_types)" do
			regi = PG::BasicTypeRegistry.new
			res = regi.define_default_types

			expect( res ).to be( regi )
			expect( regi.coders_for(0, :encoder)['float8'] ).to be_kind_of(PG::TextEncoder::Float)
			expect( regi.coders_for(0, :decoder)['float8'] ).to be_kind_of(PG::TextDecoder::Float)
		end

		it "can register_coder" do
			regi = PG::BasicTypeRegistry.new
			enco = PG::BinaryEncoder::Int8.new(name: 'test')
			res = regi.register_coder(enco)

			expect( res ).to be( regi )
			expect( regi.coders_for(1, :encoder)['test'] ).to be(enco)
			expect( regi.coders_for(1, :decoder)['test'] ).to be_nil
		end

		it "checks format and direction in coders_for" do
			regi = PG::BasicTypeRegistry.new
			expect( regi.coders_for 0, :encoder ).to eq( nil )
			expect{ regi.coders_for 0, :coder }.to raise_error( ArgumentError )
			expect{ regi.coders_for 2, :encoder }.to raise_error( ArgumentError )
		end
	end
end

# -*- rspec -*-
# encoding: utf-8

require_relative '../helpers'
require 'pg'
require 'objspace'

describe PG::VeryLazyTuple do
	let!(:typemap) { PG::BasicTypeMapForResults.new(@conn) }
	let!(:result2x2) { @conn.exec( "VALUES(1, 'a'), (2, 'b')" ) }
	let!(:result2x2cast) { @conn.exec( "VALUES(1, TRUE), (2, FALSE)" ).map_types!(typemap) }
	let!(:tuple0) { result2x2.tuple_values_very_lazy(0) }
	let!(:tuple1) { result2x2.tuple_values_very_lazy(1) }
	let!(:tuple2) { result2x2cast.tuple_values_very_lazy(0) }
	let!(:tuple3) { str = Marshal.dump(result2x2cast.tuple_values_very_lazy(1)); Marshal.load(str) }
	let!(:tuple_empty) { PG::VeryLazyTuple.new }

	describe "[]" do
		it "raises proper errors for invalid index" do
			expect{ tuple0[2] }.to raise_error(IndexError)
			expect{ tuple0[-1] }.to raise_error(IndexError)
			expect{ tuple0["x"] }.to raise_error(TypeError)
			expect{ tuple_empty[0] }.to raise_error(TypeError)
		end

		it "returns the field values" do
			expect( tuple0[0] ).to eq( "1" )
			expect( tuple0[1] ).to eq( "a" )
			expect( tuple1[0] ).to eq( "2" )
			expect( tuple1[1] ).to eq( "b" )
			expect( tuple2[0] ).to eq( 1 )
			expect( tuple2[1] ).to eq( true )
			expect( tuple3[0] ).to eq( 2 )
			expect( tuple3[1] ).to eq( false )
		end

		it "casts lazy and caches result" do
			a = []
			deco = Class.new(PG::SimpleDecoder) do
				define_method(:decode) do |*args|
					a << args
					args.last
				end
			end.new

			result2x2.map_types!(PG::TypeMapByColumn.new([deco, deco]))
			t = result2x2.tuple_values_very_lazy(1)

			# cast and cache at first call to [0]
			a.clear
			expect( t[0] ).to eq( 0 )
			expect( a ).to eq([["2", 1, 0]])

			# use cache at second call to [0]
			a.clear
			expect( t[0] ).to eq( 0 )
			expect( a ).to eq([])

			# cast and cache at first call to [1]
			a.clear
			expect( t[1] ).to eq( 1 )
			expect( a ).to eq([["b", 1, 1]])
		end
	end

	describe "each" do
		it "can be used as an enumerator" do
			expect( tuple0.each ).to be_kind_of(Enumerator)
			expect( tuple0.each.to_a ).to eq( ["1", "a"] )
			expect( tuple1.each.to_a ).to eq( ["2", "b"] )
			expect( tuple2.each.to_a ).to eq( [1, true] )
			expect( tuple3.each.to_a ).to eq( [2, false] )
			expect{ tuple_empty.each }.to raise_error(TypeError)
		end

		it "can be used with block" do
			a = []
			tuple0.each do |v|
				a << v
			end
			expect( a ).to eq( ["1", "a"] )
		end
	end

	it "can be used as Enumerable" do
		expect( tuple0.to_a ).to eq( ["1", "a"] )
		expect( tuple1.to_a ).to eq( ["2", "b"] )
		expect( tuple2.to_a ).to eq( [1, true] )
		expect( tuple3.to_a ).to eq( [2, false] )
	end

	it "can be marshaled" do
		[tuple0, tuple1, tuple2, tuple3].each do |t1|
			str = Marshal.dump(t1)
			t2 = Marshal.load(str)

			expect( t2 ).to be_kind_of(t1.class)
			expect( t2 ).not_to equal(t1)
			expect( t2.to_a ).to eq(t1.to_a)
		end
	end

	it "can't be marshaled when empty" do
		expect{ Marshal.dump(tuple_empty) }.to raise_error(TypeError)
	end

	it "should give account about memory usage" do
		expect( ObjectSpace.memsize_of(tuple0) ).to be > 0
	end

	it "should override #inspect" do
		expect( tuple2.inspect ).to eq("#<PG::VeryLazyTuple 1, true>")
		expect{ tuple_empty.inspect }.to raise_error(TypeError)
	end
end

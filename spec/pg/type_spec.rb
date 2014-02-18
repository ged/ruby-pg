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

describe PG::Type do

	it "should offer decode method with tuple/field" do
		res = PG::Type::Text::INT8.decode("123", 1, 1)
		res.should == 123
	end

	it "should offer decode method without tuple/field" do
		res = PG::Type::Text::INT8.decode("234")
		res.should == 234
	end

	it "should raise when decode method has wrong args" do
		expect{ PG::Type::Text::INT8.decode() }.to raise_error(ArgumentError)
		expect{ PG::Type::Text::INT8.decode("123", 2, 3, 4) }.to raise_error(ArgumentError)
		expect{ PG::Type::Text::INT8.decode(2, 3, 4) }.to raise_error(TypeError)
	end

	it "should offer encode method for text type" do
		res = PG::Type::Text::INT8.encode(123)
		res.should == "123"
	end

	it "should offer encode method for binary type" do
		res = PG::Type::Binary::INT4.encode(123)
		res.should == [123].pack("N")
	end
end

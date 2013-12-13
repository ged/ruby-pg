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

	it "should offer encode method" do
		res = PG::Type::Text::INT8.encode(123)
		res.should == "123"
	end

	it "should offer decode method" do
		res = PG::Type::Text::INT8.decode(PG::Result.new, 1, 1, "123")
		res.should == 123
	end

	it "should offer encode method" do
		PG::Type::Binary::INT8.encode(123)
	end
end

#!/usr/bin/env rspec
# encoding: utf-8

BEGIN {
	require 'pathname'

	basedir = Pathname( __FILE__ ).dirname.parent
	libdir = basedir + 'lib'

	$LOAD_PATH.unshift( basedir.to_s ) unless $LOAD_PATH.include?( basedir.to_s )
	$LOAD_PATH.unshift( libdir.to_s ) unless $LOAD_PATH.include?( libdir.to_s )
}

require 'rspec'
require 'spec/lib/helpers'
require 'pg'

describe PG do

	it "knows what version of the libpq library is loaded", :postgresql_91 do
		PG.library_version.should be_an( Integer )
		PG.library_version.should >= 90100
	end


	it "knows whether or not the library is threadsafe" do
		PG.should be_threadsafe()
	end

end


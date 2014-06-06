#!/usr/bin/env rspec
# encoding: utf-8

require_relative 'helpers'

require 'pg'

describe PG do

	it "knows what version of the libpq library is loaded", :postgresql_91 do
		expect( PG.library_version ).to be_an( Integer )
		expect( PG.library_version ).to be >= 90100
	end


	it "knows whether or not the library is threadsafe" do
		expect( PG ).to be_threadsafe()
	end

	it "does have hierarchical error classes" do
		expect( PG::UndefinedTable.ancestors[0,4] ).to eq([
				PG::UndefinedTable,
				PG::SyntaxErrorOrAccessRuleViolation,
				PG::ServerError,
		        PG::Error
		        ])

		expect( PG::InvalidSchemaName.ancestors[0,3] ).to eq([
				PG::InvalidSchemaName,
				PG::ServerError,
		        PG::Error
		        ])
	end

end


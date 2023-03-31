# -*- rspec -*-
# encoding: utf-8

require_relative '../helpers'

require 'pg'

describe PG::Error do

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

	it "can be used to raise errors without text" do
		expect{ raise PG::InvalidTextRepresentation }.to raise_error(PG::InvalidTextRepresentation)
	end

	it "should be delivered by Ractor", :ractor do
		r = Ractor.new(@conninfo) do |conninfo|
			conn = PG.connect(conninfo)
			conn.exec("SELECT 0/0")
		ensure
			conn&.finish
		end

		begin
			r.take
		rescue Exception => err
		end

		expect( err.cause ).to be_kind_of(PG::Error)
		expect{ raise err.cause }.to raise_error(PG::DivisionByZero, /division by zero/)
		expect{ raise err }.to raise_error(Ractor::RemoteError)
	end
end

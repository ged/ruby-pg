# -*- rspec -*-
# encoding: utf-8

require_relative '../helpers'
require 'pg'

if PG.library_version < 170000

	context "query cancelation" do
		it "shouldn't define PG::CancelConnection" do
			expect( !defined?(PG::CancelConnection) )
		end
	end

else
	describe PG::CancelConnection do
		let!(:conn) { PG::CancelConnection.new(@conn) }

		describe ".new" do
			it "needs a PG::Connection" do
				expect { PG::CancelConnection.new }.to raise_error( ArgumentError )
				expect { PG::CancelConnection.new 123 }.to raise_error( TypeError )
			end
		end

		it "fails to return a socket before connecting started" do
			expect{ conn.socket_io }.to raise_error( PG::ConnectionBad, /PQcancelSocket/ )
		end

		it "has #status" do
			expect( conn.status ).to eq( PG::CONNECTION_ALLOCATED )
		end

		it "can reset" do
			conn.reset
			conn.reset
			expect( conn.status ).to eq( PG::CONNECTION_ALLOCATED )
		end

		it "can be finished" do
			conn.finish
			conn.finish
			expect{ conn.status }.to raise_error( PG::ConnectionBad, /closed/ ) do |err|
				expect(err).to have_attributes(connection: conn)
			end
		end
	end
end

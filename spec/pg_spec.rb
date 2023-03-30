# -*- rspec -*-
# encoding: utf-8

require_relative 'helpers'

require 'pg'

describe PG do

	it "knows what version of the libpq library is loaded" do
		expect( PG.library_version ).to be_an( Integer )
		expect( PG.library_version ).to be >= 90100
	end

	it "can format the pg version" do
		expect( PG.version_string ).to be_an( String )
		expect( PG.version_string ).to match(/PG \d+\.\d+\.\d+/)
		expect( PG.version_string(true) ).to be_an( String )
		expect( PG.version_string(true) ).to match(/PG \d+\.\d+\.\d+/)
	end

	it "can select which of both security libraries to initialize" do
		# This setting does nothing here, because there is already a connection
		# to the server, at this point in time.
		PG.init_openssl(false, true)
		PG.init_openssl(1, 0)
	end

	it "can select whether security libraries to initialize" do
		# This setting does nothing here, because there is already a connection
		# to the server, at this point in time.
		PG.init_ssl(false)
		PG.init_ssl(1)
	end


	it "knows whether or not the library is threadsafe" do
		expect( PG ).to be_threadsafe()
	end

	it "tells about the libpq library path" do
		expect( PG::POSTGRESQL_LIB_PATH ).to include("/")
	end

	it "can #connect" do
		c = PG.connect(@conninfo)
		expect( c ).to be_a_kind_of( PG::Connection )
		c.close
	end

	it "can #connect with block" do
		bres = PG.connect(@conninfo) do |c|
			res = c.exec "SELECT 5"
			expect( res.values ).to eq( [["5"]] )
			55
		end

		expect( bres ).to eq( 55 )
	end
end

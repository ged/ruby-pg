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

	it "should provide constants in a Ractor", :ractor do
		vals = Ractor.new(@conninfo) do |conninfo|
			[PG.library_version, PG.version_string, PG.threadsafe?, PG::VERSION, PG::POSTGRESQL_LIB_PATH]
		end.value

		expect( vals ).to eq(
			[PG.library_version, PG.version_string, PG.threadsafe?, PG::VERSION, PG::POSTGRESQL_LIB_PATH]
		)
	end

	it "native gem's C-ext file shouldn't contain any rpath or other build-related paths" do
		skip "applies to native binary gems only" unless PG::IS_BINARY_GEM
		cext_fname = $LOADED_FEATURES.grep(/pg_ext/).first
		expect(cext_fname).not_to be_nil
		cext_text = File.binread(cext_fname)
		expect(cext_text).to match(/Init_pg_ext/) # C-ext shoud contain the init function
		expect(cext_text).not_to match(/usr\/local/) # there should be no rpath to /usr/local/rake-compiler/ruby/x86_64-unknown-linux-musl/ruby-3.4.5/lib or so
		expect(cext_text).not_to match(/home\//) # there should be no path to /home/ or so
	end

	it "native gem's libpq file shouldn't contain any rpath or other build-related paths" do
		skip "applies to native binary gems only" unless PG::IS_BINARY_GEM

		libpq_fname = case RUBY_PLATFORM
			when /mingw|mswin/ then "libpq.dll"
			when /linux/ then "libpq-ruby-pg.so.1"
			when /darwin/ then "libpq-ruby-pg.1.dylib"
		end

		path = File.join(PG::POSTGRESQL_LIB_PATH, libpq_fname)
		text = File.binread(path)
		expect(text).to match(/PQconnectdb/) # libpq shoud contain the connect function
		expect(text).not_to match(/usr\/local/) # there should be no rpath to build dirs
		expect(text).not_to match(/home\//) # there should be no path to /home/.../ports/ or so
	end
end

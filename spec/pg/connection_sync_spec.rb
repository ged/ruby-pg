# -*- rspec -*-
#encoding: utf-8

require_relative '../helpers'

context "running with sync_* methods" do
	before :each do
		PG::Connection.async_api = false
	end

	after :each do
		PG::Connection.async_api = true
	end

	fname = File.expand_path("../connection_spec.rb", __FILE__)
	eval File.read(fname, encoding: __ENCODING__), binding, fname

	it "enables async methods by #async_api" do
		PG::Connection.async_api = true

		start = Time.now
		t = Thread.new do
			@conn.exec( 'select pg_sleep(1)' )
		end
		sleep 0.1

		t.kill
		t.join

		expect( Time.now - start ).to be < 1.0
		@conn.cancel
	end

	it "disables async methods by #async_api" do
		PG::Connection.async_api = false

		start = Time.now
		t = Thread.new do
			@conn.exec( 'select pg_sleep(1)' )
		end
		sleep 0.1

		t.kill
		t.join

		expect( Time.now - start ).to be >= 1.0
		@conn.cancel
	end

end

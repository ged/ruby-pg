require 'rubygems'
require 'spec'
require 'pg'

describe PGconn do

	before( :all ) do
		@conninfo = ARGV[0]
		@conninfo = "port=5433 dbname=test user=test"
	end

	it "should connect" do
		PGconn.connect(@conninfo).status.
			should == PGconn::CONNECTION_OK
	end
end

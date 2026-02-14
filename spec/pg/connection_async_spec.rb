# -*- rspec -*-
#encoding: utf-8

require_relative '../helpers'

require 'socket'
require 'pg'

describe PG::Connection do

	it "tries to connect to localhost with IPv6 and IPv4", :ipv6 do
		uri = "postgres://localhost:#{@port+1}/test"
		expect(described_class).to receive(:parse_connect_args).once.ordered.with(uri, any_args).and_call_original
		expect(described_class).to receive(:parse_connect_args).once.ordered.with(hash_including(hostaddr: "::1,127.0.0.1")).and_call_original
		expect{ described_class.connect( uri ) }.to raise_error(PG::ConnectionBad)
	end

	def interrupt_thread(exc=nil)
		start = Time.now
		t = Thread.new do
			begin
				yield
			rescue Exception => err
				err
			end
		end
		sleep 0.1

		if exc
			t.raise exc, "Stop the query by #{exc}"
		else
			t.kill
		end
		t.join

		[t, Time.now - start]
	end

	it "can stop a thread that runs a blocking query with exec" do
		t, duration = interrupt_thread do
			@conn.exec( 'select pg_sleep(10)' )
		end

		expect( t.value ).to be_nil
		expect( duration ).to be < 10
		@conn.cancel # Stop the query that is still running on the server
	end

	describe "#transaction" do

		it "stops a thread that runs a blocking transaction with exec" do
			t, duration = interrupt_thread(Interrupt) do
				@conn.transaction do |c|
					c.exec( 'select pg_sleep(10)' )
				end
			end

			expect( t.value ).to be_kind_of( Interrupt )
			expect( duration ).to be < 10
		end

		it "stops a thread that runs a failing transaction with exec" do
			t, duration = interrupt_thread(Interrupt) do
				@conn.transaction do |c|
					c.exec( 'select nonexist' )
				end
			end

			expect( t.value ).to be_kind_of( PG::UndefinedColumn )
			expect( duration ).to be < 10
		end

		it "stops a thread that runs a no query but a transacted ruby sleep" do
			t, duration = interrupt_thread(Interrupt) do
				@conn.transaction do
					sleep 10
				end
			end

			expect( t.value ).to be_kind_of( Interrupt )
			expect( duration ).to be < 10
		end

		it "doesn't worry about an already finished connection" do
			t, _ = interrupt_thread(Interrupt) do
				@conn.transaction do
					@conn.exec("ROLLBACK")
				end
			end

			expect( t.value ).to be_kind_of( PG::Result )
			expect( t.value.result_status ).to eq( PG::PGRES_COMMAND_OK )
		end
	end

	it "should work together with signal handlers", :unix do
		signal_received = false
		trap 'USR2' do
			signal_received = true
		end

		Thread.new do
			sleep 0.1
			Process.kill("USR2", Process.pid)
		end
		@conn.exec("select pg_sleep(0.3)")
		expect( signal_received ).to be_truthy
	end

	context "OS thread support" do
		it "Connection#exec shouldn't block a second thread" do
			t = Thread.new do
				@conn.exec( "select pg_sleep(1)" )
			end

			sleep 0.1
			expect( t ).to be_alive()
			t.kill
			@conn.cancel
		end

		it "Connection.new shouldn't block a second thread" do
			serv = nil
			t = Thread.new do
				serv = TCPServer.new( '127.0.0.1', 54320 )
				expect {
					described_class.connect( '127.0.0.1', 54320, "", "", "me", "xxxx", "somedb" )
				}.to raise_error(PG::ConnectionBad, /server closed the connection unexpectedly/)
			end

			sleep 0.5
			expect( t ).to be_alive()
			serv.close
			t.join
		end
	end

	it "doesn't duplicate hosts in conn.reset", :without_transaction, :ipv6, :postgresql_12 do
		set_etc_hosts "::1", "rubypg_test2 rubypg_test_ipv6"
		set_etc_hosts "127.0.0.1", "rubypg_test2 rubypg_test_ipv4"
		conn = described_class.connect( "postgres://rubypg_test2/test" )
		conn.exec("select 1")
		expect( conn.conninfo_hash[:host] ).to eq( "rubypg_test2,rubypg_test2" )
		expect( conn.conninfo_hash[:hostaddr] ).to eq( "::1,127.0.0.1" )
		expect( conn.conninfo_hash[:port] ).to eq( "#{@port},#{@port}" )
		expect( conn.host ).to eq( "rubypg_test2" )
		expect( conn.hostaddr ).to eq( "::1" )
		expect( conn.port ).to eq( @port )

		conn.reset
		conn.exec("select 2")
		expect( conn.conninfo_hash[:host] ).to eq( "rubypg_test2,rubypg_test2" )
		expect( conn.conninfo_hash[:hostaddr] ).to eq( "::1,127.0.0.1" )
		expect( conn.conninfo_hash[:port] ).to eq( "#{@port},#{@port}" )
		expect( conn.host ).to eq( "rubypg_test2" )
		expect( conn.hostaddr ).to eq( "::1" )
		expect( conn.port ).to eq( @port )
	end

	describe "option set_auth_data_hook", :postgresql_18  do
		before :all do
			build_oauth_validator
		end

		before :each do
			@old_env, ENV["PGOAUTHDEBUG"] = ENV["PGOAUTHDEBUG"], "UNSAFE"
		end

		it "should call prompt oauth device hook" do
			oauth_server = start_fake_oauth(@port + 3)

			verification_uri, user_code, verification_uri_complete, expires_in = nil, nil, nil, nil
			conn1, conn2 = nil, nil

			hook = proc do |conn, data|
				case data
				when PG::PromptOAuthDevice
					conn1 = conn
					verification_uri = data.verification_uri
					user_code = data.user_code
					verification_uri_complete = data.verification_uri_complete
					expires_in = data.expires_in
					true
				end
			end

			begin
				PG.connect("host=localhost port=#{@port} dbname=test user=testuseroauth oauth_issuer=http://localhost:#{@port + 3} oauth_client_id=foo", set_auth_data_hook: hook) do |conn|
					conn.exec("SELECT 1")
					conn2 = conn
				end
			rescue PG::ConnectionBad => e
				if e.message =~ /no OAuth flows are available/
					skip "requires libpq-oauth to be installed"
				end
				raise
			ensure
				oauth_server.shutdown
			end

			expect(conn1).to eq(conn2)
			expect(verification_uri).to eq("http://localhost:#{@port + 3}/verify")
			expect(user_code).to eq("666")
			expect(verification_uri_complete).to eq(nil)
			expect(expires_in).to eq(60)
		end

		it "should call oauth bearer request hook" do
			openid_configuration, scope = nil, nil
			conn1, conn2 = nil, nil

			hook = proc do |conn, data|
				case data
				when PG::OAuthBearerRequest
					conn1 = conn
					openid_configuration = data.openid_configuration
					scope = data.scope
					data.token = "yes"
					true
				end
			end

			PG.connect(host: "localhost", port: @port, dbname: "test", user: "testuseroauth", oauth_issuer: "http://localhost:#{@port + 3}", oauth_client_id: "foo", set_auth_data_hook: hook) do |conn|
				conn.exec("SELECT 1")
				conn2 = conn
			end

			expect(conn1).to eq(conn2)
			expect(openid_configuration).to eq("http://localhost:#{@port + 3}/.well-known/openid-configuration")
			expect(scope).to eq("test")
		end

		it "shouldn't garbage collect PG::Connection in use" do
			conn1 = nil
			hook = proc do |conn, data|
				case data
				when PG::OAuthBearerRequest
					data.token = "yes"
					conn1 = conn
					true
				end
			end

			GC.stress = true
			begin
				conn = PG.connect(host: "localhost", port: @port, dbname: "test", user: "testuseroauth", oauth_issuer: "http://localhost:#{@port + 3}", oauth_client_id: "foo", set_auth_data_hook: hook)
			ensure
				GC.stress = false
			end
			conn.exec("SELECT 1")

			expect(conn1).to eq(conn)
		end

		it "should garbage collect PG::Connection after use" do
			hook = proc do |conn, data|
				case data
				when PG::OAuthBearerRequest
					conn1 = conn
					openid_configuration = data.openid_configuration
					scope = data.scope
					data.token = "yes"
					true
				end
			end

			before = PG.send(:pgconn2value_size)
			20.times do
				conn = PG.connect(host: "localhost", port: @port, dbname: "test", user: "testuseroauth", oauth_issuer: "http://localhost:#{@port + 3}", oauth_client_id: "foo", set_auth_data_hook: hook)
				conn.exec("SELECT 1")
			end

			GC.start
			after = PG.send(:pgconn2value_size)

			# Number of GC'ed objects
			expect(before + 20 - after).to be_between(1, 50)
		end

		# TODO: Is resetting the global hook still useful, when the hook is per connection?
		# it "should reset the hook when called without block" do
		# 	oauth_server = start_fake_oauth(@port + 3)
		#
		# 	PG.set_auth_data_hook do |conn_num, data|
		# 		raise "broken hook"
		# 	end
		#
		# 	expect do
		# 		PG.connect("host=localhost port=#{@port} dbname=test user=testuseroauth oauth_issuer=http://localhost:#{@port + 3} oauth_client_id=foo") {}
		# 	end.to raise_error("broken hook")
		#
		# 	PG.set_auth_data_hook
		#
		# 	begin
		# 		PG.connect("host=localhost port=#{@port} dbname=test user=testuseroauth oauth_issuer=http://localhost:#{@port + 3} oauth_client_id=foo") do |conn|
		# 			conn.exec("SELECT 1")
		# 		end
		# 	rescue PG::ConnectionBad => e
		# 		if e.message =~ /no OAuth flows are available/
		# 			skip "requires libpq-oauth to be installed"
		# 		end
		# 		raise
		# 	ensure
		# 		oauth_server.shutdown
		# 	end
		# end

		# around :example do |ex|
		# 	GC.stress = true
		# 	ex.run
		# 	GC.stress = false
		# end

		after :each do
			# PG.set_auth_data_hook
			ENV["PGOAUTHDEBUG"] = @old_env
		end
	end
end

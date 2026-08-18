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

	it "connects without port and then retrieves the default port" do
		gate = Helpers::TcpGateSwitcher.new(
			external_host: 'localhost',
			external_port: ENV['PGPORT'].to_i,
			internal_host: "127.0.0.1",
			internal_port: PG::DEF_PGPORT,
			debug: ENV['PG_DEBUG']=='1')

		PG.connect(host: "localhost",
		           port: "",
		           dbname: "test") do |conn|
			expect( conn.port ).to eq( PG::DEF_PGPORT )
		end

		PG.connect(hostaddr: "127.0.0.1",
		           port: nil,
		           dbname: "test") do |conn|
			expect( conn.port ).to eq( PG::DEF_PGPORT )
		end

		gate.finish
	rescue Errno::EADDRINUSE, Errno::EACCES => err
		skip err.to_s
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

	context "in nonblocking mode" do
		after :each do
			@conn.setnonblocking(false)
		end

		it "rejects to send lots of COPY data" do
			unless RUBY_PLATFORM =~ /i386-mingw|x86_64-darwin|x86_64-linux$/
					skip "this spec depends on out-of-memory condition in put_copy_data, which is not reliable on all platforms"
			end

			run_with_gate(200) do |conn, gate|
				conn.setnonblocking(true)

				res = nil
				conn.exec <<-EOSQL
					CREATE TEMP TABLE copytable (col1 TEXT);
				EOSQL

				conn.exec( "COPY copytable FROM STDOUT CSV" )

				gate.stop

				data = "x" * 1000 * 1000
				data << "\n"
				20000.times do |idx|
					res = conn.put_copy_data(data)
					break if res == false
				end
				expect( res ).to be_falsey

				gate.start
				conn.cancel
				conn.discard_results
			end
		end

		it "needs to flush data after send_query" do
			run_with_gate(200) do |conn, gate|
				conn.setnonblocking(true)

				gate.stop
				data = "x" * 1000 * 1000 * 30
				res = conn.send_query_params("SELECT LENGTH($1)", [data])
				expect( res ).to be_nil

				res = conn.flush
				expect( res ).to be_falsey

				gate.start
				until conn.flush
					IO.select(nil, [conn.socket_io], [conn.socket_io], 10)
				end
				expect( conn.flush ).to be_truthy

				res = conn.get_last_result
				expect( res.values ).to eq( [[data.length.to_s]] )
			end
		end
	end
end

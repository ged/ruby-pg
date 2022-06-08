# -*- rspec -*-
#encoding: utf-8

require_relative '../helpers'

require 'socket'
require 'pg'

describe PG::Connection do

	it "tries to connect to localhost with IPv6 and IPv4", :ipv6 do
		uri = "postgres://localhost:#{@port+1}/test"
		expect(described_class).to receive(:parse_connect_args).once.ordered.with(uri).and_call_original
		expect(described_class).to receive(:parse_connect_args).once.ordered.with(hash_including(hostaddr: "::1")).and_call_original
		expect(described_class).to receive(:parse_connect_args).once.ordered.with(hash_including(hostaddr: "127.0.0.1")).and_call_original
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
			t, duration = interrupt_thread(Interrupt) do
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

end
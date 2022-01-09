# -*- rspec -*-
#encoding: utf-8

require_relative '../helpers'

$scheduler_timeout = false

context "with a Fiber scheduler", :scheduler do

	def setup
		# Run examples with gated scheduler
		sched = Helpers::TcpGateScheduler.new(external_host: 'localhost', external_port: ENV['PGPORT'].to_i, debug: ENV['PG_DEBUG']=='1')
		Fiber.set_scheduler(sched)
		@conninfo_gate = @conninfo.gsub(/(^| )port=\d+/, " port=#{sched.internal_port}")

		# Run examples with default scheduler
		#Fiber.set_scheduler(Helpers::Scheduler.new)
		#@conninfo_gate = @conninfo

		# Run examples without scheduler
		#def Fiber.schedule; yield; end
		#@conninfo_gate = @conninfo
	end

	def teardown
		Fiber.set_scheduler(nil)
	end

	def stop_scheduler
		if Fiber.scheduler && Fiber.scheduler.respond_to?(:finish)
			Fiber.scheduler.finish
		end
	end

	def thread_with_timeout(timeout)
		th = Thread.new do
			yield
		end
		unless th.join(timeout)
			th.kill
			$scheduler_timeout = true
			raise("scheduler timeout in:\n#{th.backtrace.join("\n")}")
		end
	end

	def run_with_scheduler(timeout=10)
		thread_with_timeout(timeout) do
			setup
			Fiber.schedule do
				conn = PG.connect(@conninfo_gate)

				yield conn

				conn.finish
				stop_scheduler
			end
		end
	end

	it "connects to a server" do
		run_with_scheduler do |conn|
			res = conn.exec_params("SELECT 7", [])
			expect(res.values).to eq([["7"]])
		end
	end

	it "connects to a server with setting default encoding" do
		Encoding.default_internal = Encoding::ISO8859_3
		begin
			run_with_scheduler do |conn|
				res = conn.exec_params("SELECT 8", [])
				expect(res.getvalue(0,0).encoding).to eq(Encoding::ISO8859_3)
				expect( conn.get_client_encoding ).to eq( "LATIN3" )
			end
		ensure
			Encoding.default_internal = nil
		end
	end

	it "can set_client_encoding" do
		run_with_scheduler do |conn|
			expect( conn.set_client_encoding('iso8859-4') ).to eq( nil )
			expect( conn.get_client_encoding ).to eq( "LATIN4" )
			conn.client_encoding = 'iso8859-2'
			expect( conn.get_client_encoding ).to eq( "LATIN2" )
		end
	end

	it "waits when sending query data" do
		run_with_scheduler do |conn|
			data = "x" * 1000 * 1000 * 10
			res = conn.exec_params("SELECT LENGTH($1)", [data])
			expect(res.values).to eq([[data.length.to_s]])
		end
	end

	it "connects several times concurrently" do
		run_with_scheduler do
			q = Queue.new
			3.times do
				Fiber.schedule do
					conn = PG.connect(@conninfo_gate)
					conn.finish
					q << true
				end
			end.times do
				q.pop
			end
		end
	end

	it "can connect with DNS lookup", :scheduler_address_resolve do
		run_with_scheduler do
			conninfo = @conninfo_gate.gsub(/(^| )host=\w+/, " host=scheduler-localhost")
			conn = PG.connect(conninfo)
			opt = conn.conninfo.find { |info| info[:keyword] == 'host' }
			expect( opt[:val] ).to eq( 'scheduler-localhost' )
			conn.finish
		end
	end

	it "can reset the connection" do
		run_with_scheduler do
			conn = PG.connect(@conninfo_gate)
			conn.exec("SET search_path TO test1")
			expect( conn.exec("SHOW search_path").values ).to eq( [["test1"]] )
			conn.reset
			expect( conn.exec("SHOW search_path").values ).to eq( [['"$user", public']] )
			conn.finish
		end
	end

	it "can retrieve several results" do
		run_with_scheduler do |conn|
			res = conn.send_query <<-EOT
				SELECT generate_series(0,999), NULL;
				SELECT 1000, pg_sleep(0.1);
			EOT

			res = conn.get_result
			expect( res.values.length ).to eq( 1000 )

			res = conn.get_result
			expect( res.values ).to eq( [["1000", ""]] )

			res = conn.get_result
			expect( res ).to be_nil
		end
	end

	it "can retrieve the last one of several results" do
		run_with_scheduler do |conn|
			res = conn.exec <<-EOT
				SELECT 1, NULL;
				SELECT 3, pg_sleep(0.1);
			EOT
			expect( res.values ).to eq( [["3", ""]] )
		end
	end

	it "can receive COPY data" do
		run_with_scheduler do |conn|
			rows = []
			conn.copy_data( "COPY (SELECT generate_series(0,999)::TEXT UNION ALL SELECT pg_sleep(1)::TEXT || '1000') TO STDOUT" ) do |res|
				res = nil
				1002.times do
					rows << conn.get_copy_data
				end
			end
			expect( rows ).to eq( 1001.times.map{|i| "#{i}\n" } + [nil] )
		end
	end

	it "can send lots of data per put_copy_data" do
		run_with_scheduler(60) do |conn|
			conn.exec <<-EOSQL
				CREATE TEMP TABLE copytable (col1 TEXT);
			EOSQL

			res = nil
			conn.copy_data( "COPY copytable FROM STDOUT CSV" ) do
				data = "x" * 1000 * 1000
				data << "\n"
				50.times do
					res = conn.put_copy_data(data)
					break if res == false
				end
			end
			expect( res ).to be_truthy
		end
	end

	it "discards any pending results" do
		run_with_scheduler do |conn|
			conn.send_query("SELECT 5")
			res = conn.exec("SELECT 6")
			expect( res.values ).to eq( [["6"]] )
		end
	end

	it "can discard_results after query" do
		run_with_scheduler do |conn|
			conn.send_query("SELECT 7")
			conn.discard_results
			conn.send_query("SELECT 8")
			res = conn.get_result
			expect( res.values ).to eq( [["8"]] )
		end
	end

	it "can discard_results after COPY FROM STDIN" do
		run_with_scheduler do |conn|
			conn.exec( "CREATE TEMP TABLE copytable (col1 TEXT)" )
			conn.exec( "COPY copytable FROM STDIN" )
			conn.discard_results
			conn.send_query("SELECT 2")
			res = conn.get_result
			expect( res.values ).to eq( [["2"]] )
		end
	end

	it "can discard_results after COPY TO STDOUT" do
		run_with_scheduler do |conn|
			conn.exec("COPY (SELECT generate_series(0,999)::TEXT UNION ALL SELECT pg_sleep(1)::TEXT || '1000') TO STDOUT" )
			conn.discard_results
			conn.send_query("SELECT 3")
			res = conn.get_result
			expect( res.values ).to eq( [["3"]] )
		end
	end

	it "should convert strings and parameters to #prepare and #exec_prepared" do
		run_with_scheduler do |conn|
			conn.prepare("weiß1", "VALUES( LENGTH($1), 'grün')")
			data = "x" * 1000 * 1000 * 10
			r = conn.exec_prepared("weiß1", [data])
			expect( r.values ).to eq( [[data.length.to_s, 'grün']] )
		end
	end

	it "should convert strings to #describe_prepared" do
		run_with_scheduler do |conn|
			conn.prepare("weiß2", "VALUES(123)")
			r = conn.describe_prepared("weiß2")
			expect( r.nfields ).to eq( 1 )
		end
	end

	it "should convert strings to #describe_portal" do
		run_with_scheduler do |conn|
			conn.transaction do
				conn.exec "DECLARE cörsör CURSOR FOR VALUES(1,2,3)"
				r = conn.describe_portal("cörsör")
				expect( r.nfields ).to eq( 3 )
			end
		end
	end

	it "can cancel a query" do
		run_with_scheduler do |conn|
			conn.send_query "SELECT pg_sleep(5)"
			conn.block(0.1) # trigger transmission to the server
			conn.cancel
			expect{ conn.get_last_result }.to raise_error(PG::QueryCanceled)
		end
	end

	it "can encrypt_password", :postgresql_10 do
		run_with_scheduler do |conn|
			res = conn.encrypt_password "passw", "myuser"
			expect( res ).to  match( /\S+/ )
			res = conn.encrypt_password "passw", "myuser", "md5"
			expect( res ).to eq( "md57883f68fde2c10fdabfb7640c74cf1a7" )
		end
	end

	it "can ping server" do
		run_with_scheduler do |conn|
			# ping doesn't trigger the scheduler, but runs in a second thread.
			# This is why @conninfo is used instead of @conninfo_gate
			ping = PG::Connection.ping(@conninfo)
			expect( ping ).to eq( PG::PQPING_OK )
		end
	end
end

# Do not wait for threads doing blocking calls at the process shutdown.
# Instead exit immediately after printing the rspec report, if we know there are pending IO calls, which do not react on ruby interrupts.
END{
	if $scheduler_timeout
		exit!(1)
	end
}

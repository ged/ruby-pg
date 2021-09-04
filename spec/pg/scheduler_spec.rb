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

	it "waits when sending data" do
		run_with_scheduler do |conn|
			data = "x" * 1000 * 1000 * 10
			res = conn.exec_params("SELECT LENGTH($1)", [data])
			expect(res.values).to eq([[data.length.to_s]])
		end
	end

	it "connects several times" do
		run_with_scheduler do
			3.times do
				conn = PG.connect(@conninfo_gate)
				conn.finish
			end
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
end

# Do not wait for threads doing blocking calls at the process shutdown.
# Instead exit immediately after printing the rspec report, if we know there are pending IO calls, which do not react on ruby interrupts.
END{
	if $scheduler_timeout
		exit!(1)
	end
}

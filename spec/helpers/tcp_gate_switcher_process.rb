# frozen_string_literal: true

require 'drb/drb'

# This is a wrapper of TcpGateSwitcher running in a separate process to avoid the need of threads.
# It can therefore be used in conjunction with blocking GVL locking functions.

module Helpers
class TcpGateSwitcherProcess
	def initialize(**kwargs)
		file = File.expand_path("tcp_gate_switcher", __dir__)
		rbtext = <<~RBTEXT
			require #{file.inspect}
			require "drb/drb"

			switcher = Helpers::TcpGateSwitcher.allocate
			def switcher.finish
				super
				DRb.stop_service
			end
			def switcher.init
				initialize(**#{kwargs.inspect})
				self
			end
			DRb.start_service('druby://localhost:0', switcher)
			puts DRb.uri
			# Redirect STDOUT to STDERR, so that p prints to STDERR
			STDOUT.reopen(STDERR)

			# Wait for the drb server thread to finish before exiting.
			DRb.thread.join
			# puts "TcpGateSwitcherProcess finished"
		RBTEXT

		io = IO.popen("ruby", "w+")
		io.write rbtext
		io.close_write
		server_uri = io.gets.strip
		@server = DRbObject.new_with_uri(server_uri)
		# Call initialize through DRb, so that Exceptions are passed to caller
		@server.init
	rescue
		@server&.finish
		raise
	end

	%i[finish internal_port start stop].each do |meth|
		define_method(meth) do
			@server.send(meth)
		end
	end
end
end

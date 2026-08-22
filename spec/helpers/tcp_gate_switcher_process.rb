# frozen_string_literal: true

require 'drb/drb'

# This is a wrapper of TcpGateSwitcher running in a separate process to avoid the need of threads.
# It can therefore be used in conjunction with blocking GVL locking functions.

module Helpers
class TcpGateSwitcherProcess
	def initialize
		file = File.expand_path("tcp_gate_switcher", __dir__)
		rbtext = <<~RBTEXT
			require #{file.inspect}
			require "drb/drb"

			switcher = Helpers::TcpGateSwitcher.new
			def switcher.finish
				super
				DRb.stop_service
			end
			DRb.start_service('druby://localhost:0', switcher)
			puts DRb.uri
			# Redirect STDOUT to STDERR, so that p prints to STDERR
			STDOUT.reopen(STDERR)

			# Wait for the drb server thread to finish before exiting.
			DRb.thread.join
		RBTEXT

		io = IO.popen("ruby", "w+")
		io.write rbtext
		io.close_write
		server_uri = io.gets.strip
		@server = DRbObject.new_with_uri(server_uri)
	end

	%i[bind finish internal_port start stop].each do |meth|
		define_method(meth) do |*args, **kwargs|
			@server.send(meth, *args, **kwargs)
		end
	end
end
end

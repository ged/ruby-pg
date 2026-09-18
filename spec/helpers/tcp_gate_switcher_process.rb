# frozen_string_literal: true

require 'drb/drb'
require 'rbconfig'

# This is a wrapper of TcpGateSwitcher running in a separate process to avoid the need of threads.
# It can therefore be used in conjunction with blocking GVL locking functions.

module Helpers
class TcpGateSwitcherProcess
	def initialize(**kwargs)
		@io = IO.popen([RbConfig::CONFIG['ruby_install_name'], __FILE__])
		server_uri = @io.gets.strip
		@server = DRbObject.new_with_uri(server_uri)
		# Call initialize through DRb, so that Exceptions are passed to caller
		@server.init(kwargs)
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

if $0 == __FILE__
	require_relative "tcp_gate_switcher"

	switcher = Helpers::TcpGateSwitcher.allocate
	def switcher.finish
		super
		DRb.stop_service
	end
	def switcher.init(kwargs)
		initialize(**kwargs)
		self
	end
	DRb.start_service('druby://localhost:0', switcher)
	puts DRb.uri
	# Redirect STDOUT to STDERR, so that p prints to STDERR
	STDOUT.reopen(STDERR)

	# Wait for the drb server thread to finish before exiting.
	DRb.thread.join
	# puts "TcpGateSwitcherProcess finished"
end

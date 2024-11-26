# -*- ruby -*-
# frozen_string_literal: true

require 'pg' unless defined?( PG )

if defined?(PG::CancelConnection)
	class PG::CancelConnection
		include PG::Connection::Pollable

		# The timeout used by #cancel and async_cancel to establish the cancel connection.
		attr_accessor :async_connect_timeout

		# call-seq:
		#    conn.cancel
		#
		# Requests that the server abandons processing of the current command in a blocking manner.
		#
		# If the cancel request wasn't successfully dispatched an error message is raised.
		#
		# Successful dispatch of the cancellation is no guarantee that the request will have any effect, however.
		# If the cancellation is effective, the command being canceled will terminate early and raises an error.
		# If the cancellation fails (say, because the server was already done processing the command), then there will be no visible result at all.
		#
		def cancel
			start
			polling_loop(:poll, async_connect_timeout)
		end
		alias async_cancel cancel
	end
end

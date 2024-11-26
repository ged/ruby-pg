# -*- ruby -*-
# frozen_string_literal: true

require 'pg' unless defined?( PG )

if defined?(PG::CancelConnection)
	class PG::CancelConnection
		include PG::Connection::Pollable

		# The timeout used by async_cancel to establish the cancel connection.
		attr_accessor :async_connect_timeout

		def async_cancel
			start
			polling_loop(:poll, async_connect_timeout)
		end
	end
end

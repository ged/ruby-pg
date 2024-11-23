# frozen_string_literal: true

# This is a special scheduler for testing compatibility to Fiber.scheduler of functions using a TCP connection.
#
# It works as a gatekeeper between the client and the server.
# Data is transferred only, when the scheduler receives wait_io requests.
# The TCP communication in a C extension can be verified in a timing insensitive way.
# If a call waits for IO but doesn't call the scheduler, the test will block and can be caught by an external timeout.
#
#   PG.connect       intern                              extern
#    port:5444        side        TcpGateScheduler        side         DB
#  -------------      ----------------------------------------      --------
#  | scheduler |      | TCPServer                  TCPSocket |      |      |
#  |   specs   |----->|  port 5444                  port 5432|----->|Server|
#  -------------  ^   |                                      |      | port |
#                 '-------  wait_readable:  <--read data--   |      | 5432 |
#           observe fd|     wait_writable:  --write data->   |      --------
#                     ----------------------------------------

module Helpers
class TcpGateScheduler < Scheduler
	class Connection
		attr_reader :internal_io
		attr_reader :external_io
		attr_accessor :observed_fd

		def initialize(internal_io, external_host, external_port, debug: false)
			@internal_io = internal_io
			@external_host = external_host
			@external_port = external_port
			@external_io = nil
			@pending_connect = false
			@pending_read = false
			@pending_write = false
			@debug = debug
		end

		def other_side_of?(local_address, remote_address)
			internal_io.local_address.to_s == remote_address && internal_io.remote_address.to_s == local_address
		rescue Errno::ENOTCONN, Errno::EINVAL
			# internal_io.remote_address fails, if connection is already half closed
			false
		end

		def print_data(desc, data)
			return unless @debug
			if data.bytesize >= 70
				sdata = data[0..70]
				puts "#{desc}: #{sdata.inspect} (... #{data.bytesize} bytes)"
			else
				puts "#{desc}: #{data.inspect} (#{data.bytesize} bytes)"
			end
		end

		def puts(*args)
			return unless @debug
			super
		end

		def connect
			# Not yet connected?
			if !@external_io
				if !@pending_connect
					@pending_connect = Queue.new
					@external_io = TCPSocket.new(@external_host, @external_port)
					@pending_connect.close
					@pending_connect = false
					puts "connected ext:#{@external_io.inspect} (belongs to int:#{@internal_io.fileno})"
				else
					# connection is being established -> wait for it before doing read/write
					@pending_connect.pop
				end
			end
		end

		# transfer data in read direction
		#
		# Option `transfer_until` can be (higher to lower priority):
		#   :eof => transfer until channel is closed
		#   false => transfer only one block
		#
		# The method does nothing if a transfer is already pending, but might raise the transfer_until option, if the requested priority is higher than the pending transfer.
		def read( transfer_until: )
			if !@pending_read
				@pending_read = true
				@transfer_until = transfer_until

				Fiber.schedule do
					connect

					begin
						begin
							# 140 bytes transfer is required to trigger an error in spec "can cancel a query", when get_last_error doesn't wait for readability between PQgetResult calls.
							# TODO: Make an explicit spec for this case.
							read_str = @external_io.read_nonblock(140)
							print_data("read-transfer #{read_fds}", read_str)
							@internal_io.write(read_str)
						rescue IO::WaitReadable, Errno::EINTR
							@external_io.wait_readable
							retry
						rescue EOFError, Errno::ECONNRESET
							puts "read_eof from #{read_fds}"
							@internal_io.close_write
							break
						end
					end while @transfer_until
					@pending_read = false
				end
			elsif transfer_until == :eof
				@transfer_until = transfer_until
			end
		end

		# transfer data in write direction
		#
		# Option `transfer_until` can be (higher to lower priority):
		#   :eof => transfer until channel is closed
		#   :wouldblock => transfer until no immediate data is available
		#   IO object => transfer until IO is writable
		#
		# The method does nothing if a transfer is already pending, but might raise the transfer_until option, if the requested priority is higher than the pending transfer.
		def write( transfer_until: )
			if !@pending_write
				@pending_write = true
				@transfer_until = transfer_until

				Fiber.schedule do
					connect

					# transfer data blocks of up to 65536 bytes
					# until the observed connection is writable again or
					# no data left to read
					loop do
						len = 65536
						begin
							read_str = @internal_io.read_nonblock(len)
							print_data("write-transfer #{write_fds}", read_str)
							sleep 0
							@external_io.write(read_str)
							if @transfer_until.is_a?(IO)
								res = IO.select(nil, [@transfer_until], nil, 0) rescue nil
								if res
									puts "stop writing - #{@transfer_until.inspect} is writable again"
									break
								end
							end

						rescue IO::WaitReadable, Errno::EINTR
							@internal_io.wait_readable
							retry
						rescue EOFError, Errno::ECONNRESET, Errno::ECONNABORTED
							puts "write_eof from #{write_fds}"
							@external_io.close_write
							break
						end
						break if @transfer_until != :eof && (!read_str || read_str.empty?)
					end
					@pending_write = false
				end

			elsif (transfer_until == :wouldblock && @transfer_until.is_a?(IO)) ||
					transfer_until == :eof
				# If a write request without stopping on writablility comes in,
				# make sure, that the pending transfer doesn't abort prematurely.
				@transfer_until = transfer_until
			end
		end

		def read_fds
			"ext:#{@external_io&.fileno || '-'}->int:#{@internal_io.fileno} obs:#{observed_fd}"
		end

		def write_fds
			"int:#{@internal_io.fileno}->ext:#{@external_io&.fileno || '-'} obs:#{observed_fd}"
		end

		# Make sure all data is transferred and both connections are closed.
		def finish
			puts "finish transfers #{write_fds} and #{read_fds}"
			write transfer_until: :eof
			read transfer_until: :eof
		end
	end

	UnknownConnection = Struct.new :fileno, :events

	def initialize(external_host:, external_port:, internal_host: 'localhost', internal_port: 0, debug: false)
		super()
		@started = false
		@connections = []
		@unknown_connections = {}
		@server_io = TCPServer.new(internal_host, internal_port)
		@external_host = external_host
		@external_port = external_port
		@finish = false
		@debug = debug
		@in_puts = false
		puts "TcpGate server listening: #{@server_io.inspect}"
	end

	def finish
		@finish = true
		TCPSocket.new('localhost', internal_port).close
	end

	def internal_port
		@server_io.local_address.ip_port
	end

	def puts(*args)
		return if !@debug || @in_puts # Avoid recursive calls of puts
		@in_puts = true
		super
	ensure
		@in_puts = false
	end

	def io_wait(io, events, duration)
		puts "io_wait(#{io.inspect}, #{events}, #{duration}) from #{caller[0]}"

		begin
			sock = TCPSocket.for_fd(io.fileno)
			sock.autoclose = false
			local_address = sock.local_address.to_s
			remote_address = sock.remote_address.to_s
		rescue Errno::ENOTCONN, Errno::EINVAL, Errno::EBADF
		end

		unless @started
			@started = true
			Fiber.schedule do
				# Wait for new connections to the TCP gate
				while client=@server_io.accept
					if @finish
						@connections.each(&:finish)
						break
					else
						conn = Connection.new(client, @external_host, @external_port, debug: @debug)
						puts "accept new int:#{conn.internal_io.inspect} from #{conn.internal_io.remote_address.inspect} server fd:#{@server_io.fileno}"
						@connections << conn

						# Have there been any events on the connection before accept?
						if uconn=@unknown_connections.delete([conn.internal_io.remote_address.to_s, conn.internal_io.local_address.to_s])
							conn.observed_fd = uconn.fileno

							if (uconn.events & IO::WRITABLE) > 0
								puts "late-write-trigger #{conn.write_fds} until wouldblock"
								conn.write(transfer_until: :wouldblock)
							end
							if (uconn.events & IO::READABLE) > 0
								puts "late-read-trigger #{conn.read_fds} single block"
								conn.read(transfer_until: false)
							end
						end
					end
				end
			end
		end

		# Remove old connections
		@connections.reject! do |conn|
			conn.internal_io.closed? || conn.external_io&.closed?
		end

		# Some IO call is waiting for data by rb_wait_for_single_fd() or so.
		# Is it on our intercepted IO?
		# Inspect latest connections first, since closed connections aren't removed immediately.
		if cidx=@connections.rindex { _1.other_side_of?(local_address, remote_address) }
			conn = @connections[cidx]
			# Success! Our observed client IO waits for some data to be readable or writable.
			# The IO function running on the observed IO did make proper use of some ruby wait function.
			# As a reward we provide some data to read or write.
			#
			# To the contrary:
			# If the blocking IO function doesn't make use of ruby wait functions, then it won't get any data and starve as a result.

			# compare and store the fileno for debugging
			if conn.observed_fd && conn.observed_fd != io.fileno
				puts "observed fd changed: old:#{conn.observed_fd} new:#{io.fileno}"
			end
			conn.observed_fd = io.fileno

			if (events & IO::WRITABLE) > 0
				puts "write-trigger #{conn.write_fds} until #{io.fileno} writable"
				conn.write(transfer_until: io)

				if (events & IO::READABLE) > 0
					puts "read-trigger #{conn.read_fds} single block"
					conn.read(transfer_until: false)
				end
			else
				if (events & IO::READABLE) > 0
					puts "write-trigger #{conn.write_fds} until wouldblock"
					# libpq waits for writablility only in a would-block case and not before writing.
					# Since our incoming IO probably doesn't block, we get no write-trigger although data was written to the observed IO.
					# But after writing some data the caller usually waits for some answer to read.
					# We take this event as a trigger to transfer all pending written data.
					conn.write(transfer_until: :wouldblock)

					puts "read-trigger #{conn.read_fds} single block"
					conn.read(transfer_until: false)
				end
			end
		else
			# Maybe the connection is not yet accepted.
			# We store it to do the transfer after accept arrived.
			if uc=@unknown_connections[[local_address, remote_address]]
				uc.events |= events
			else
				@unknown_connections[[local_address, remote_address]] = UnknownConnection.new(io.fileno, events)
			end
		end

		super
	end

	# Rewrite the hostname to verify that address resolution goes through the scheduler.
	def address_resolve(hostname)
		if hostname =~ /\Ascheduler-(.*)/
			hostname = $1
		end
		super(hostname)
	end
end
end

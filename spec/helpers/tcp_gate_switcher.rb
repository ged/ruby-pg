# frozen_string_literal: true

# This is a transparent TCP proxy for testing blocking behaviour in a time insensitive way.
#
# It works as a gate between the client and the server, which is enabled or disabled by the spec.
# Data transfer can be blocked per API.
# The TCP communication in a C extension can be verified in a (mostly) timing insensitive way.
# If a call does IO but doesn't handle non-blocking state, the test will block and can be caught by an external timeout.
#
#
#   PG.connect       intern       TcpGateSwitcher        extern
#    port:5444        .--------------------------------------.
#        .--start/stop---------------> T                     |         DB
#  .-----|-----.      |                | /                   |      .------.
#  |    non-   |      |                |/                    |      |Server|
#  |  blocking |      | TCPServer      /           TCPSocket |      | port |
#  |   specs   |------->port 5444-----/   ---------port 5432------->| 5432 |
#  '-----------'      '--------------------------------------'      '------'

module Helpers
class TcpGateSwitcher
	class Connection
		attr_reader :internal_io
		attr_reader :external_io

		def initialize(internal_io, external_host, external_port, debug: false)
			@internal_io = internal_io
			@external_host = external_host
			@external_port = external_port
			@external_io = nil
			@mutex = Mutex.new
			@debug = debug
			@wait = nil

			@th1 = Thread.new do
				read
			end
			@th2 = Thread.new do
				write
			end
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
			@mutex.synchronize do
				if !@external_io
					@external_io = TCPSocket.new(@external_host, @external_port)
					puts "connected ext:#{@external_io.inspect} (belongs to int:#{@internal_io.fileno})"
				end
			end
		end

		# transfer data in read direction
		def read
			connect

			loop do
				@wait&.deq
				begin
					read_str = @external_io.read_nonblock(65536)
					print_data("read-transfer #{read_fds}", read_str)
					@internal_io.write(read_str)
				rescue IO::WaitReadable, Errno::EINTR
					@external_io.wait_readable
				rescue EOFError, Errno::ECONNRESET
					puts "read_eof from #{read_fds}"
					@internal_io.close_write
					break
				end
			end
		end

		# transfer data in write direction
		def write
			connect

			# transfer data blocks of up to 65536 bytes
			loop do
				@wait&.deq
				begin
					read_str = @internal_io.read_nonblock(65536)
					print_data("write-transfer #{write_fds}", read_str)
					# Workaround for sporadic "SSL error: ssl/tls alert bad record mac"
					sleep 0.001 if RUBY_ENGINE=="truffleruby"
					@external_io.write(read_str)
				rescue IO::WaitReadable, Errno::EINTR
					@internal_io.wait_readable
				rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
					puts "write_eof from #{write_fds}"
					@external_io.close_write
					break
				end
			end
		end

		def read_fds
			"ext:#{@external_io&.fileno || '-'}->int:#{@internal_io.fileno}"
		end

		def write_fds
			"int:#{@internal_io.fileno}->ext:#{@external_io&.fileno || '-'}"
		end

		# Make sure all data is transferred and both connections are closed.
		def finish
			puts "finish transfers #{write_fds} and #{read_fds}"
			@th1.join
			@th2.join
		end

		def start
			@wait&.close
			@wait = nil
		end

		def stop
			@wait ||= Queue.new
		end
	end

	UnknownConnection = Struct.new :fileno, :events

	def initialize(external_host:, external_port:, internal_host: 'localhost', internal_port: 0, debug: false)
		super()
		@connections = []
		@server_io = TCPServer.new(internal_host, internal_port)
		@external_host = external_host
		@external_port = external_port
		@finish = false
		@debug = debug
		puts "TcpGate server listening: #{@server_io.inspect}"

		@th = run
	end

	def finish
		@finish = true
		TCPSocket.new('localhost', internal_port).close
		@th.join
	end

	def internal_port
		@server_io.local_address.ip_port
	end

	def start
		@connections.each(&:start)
	end

	def stop
		@connections.each(&:stop)
	end

	def run
		Thread.new do
			# Wait for new connections to the TCP gate
			while client=@server_io.accept
				if @finish
					@connections.each(&:finish)
					break
				else
					conn = Connection.new(client, @external_host, @external_port, debug: @debug)
					puts "accept new int:#{conn.internal_io.inspect} from #{conn.internal_io.remote_address.inspect} server fd:#{@server_io.fileno}"
					@connections << conn

					# Unblock read and write transfer
					conn.start
				end

				# Remove old connections
				@connections.reject! do |conn|
					conn.internal_io.closed? || conn.external_io&.closed?
				end
			end
		end
	end
end
end

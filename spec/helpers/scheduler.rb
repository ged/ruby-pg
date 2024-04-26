# frozen_string_literal: true

# This file is copied from https://github.com/ruby/ruby/blob/5e9598baea97c53757f12713bacc7f19f315c846/test/fiber/scheduler.rb

# This is an example and simplified scheduler for test purposes.
# It is not efficient for a large number of file descriptors as it uses IO.select().
# Production Fiber schedulers should use epoll/kqueue/etc.

require 'fiber'
require 'socket'

begin
	require 'io/nonblock'
rescue LoadError
	# Ignore.
end

module Helpers
class Scheduler
	def initialize
		@readable = {}
		@writable = {}
		@waiting = {}

		@closed = false

		@lock = Thread::Mutex.new
		@blocking = Hash.new.compare_by_identity
		@ready = []

		@urgent = IO.pipe
	end

	attr :readable
	attr :writable
	attr :waiting

	def next_timeout
		_fiber, timeout = @waiting.min_by{|key, value| value}

		if timeout
			offset = timeout - current_time

			if offset < 0
				return 0
			else
				return offset
			end
		end
	end

	def run
		# $stderr.puts [__method__, Fiber.current].inspect

		while @readable.any? or @writable.any? or @waiting.any? or @blocking.any?
			# Can only handle file descriptors up to 1024...
			readable, writable = IO.select(@readable.keys + [@urgent.first], @writable.keys, [], next_timeout)

			# puts "readable: #{readable}" if readable&.any?
			# puts "writable: #{writable}" if writable&.any?

			selected = {}

			readable&.each do |io|
				if fiber = @readable.delete(io)
					@writable.delete(io) if @writable[io] == fiber
					selected[fiber] = IO::READABLE
				elsif io == @urgent.first
					@urgent.first.read_nonblock(1024)
				end
			end

			writable&.each do |io|
				if fiber = @writable.delete(io)
					@readable.delete(io) if @readable[io] == fiber
					selected[fiber] = selected.fetch(fiber, 0) | IO::WRITABLE
				end
			end

			selected.each do |fiber, events|
				fiber.resume(events)
			end

			if @waiting.any?
				time = current_time
				waiting, @waiting = @waiting, {}

				waiting.each do |fiber, timeout|
					if fiber.alive?
						if timeout <= time
							fiber.resume
						else
							@waiting[fiber] = timeout
						end
					end
				end
			end

			if @ready.any?
				ready = nil

				@lock.synchronize do
					ready, @ready = @ready, []
				end

				ready.each do |fiber|
					fiber.resume
				end
			end
		end
	end

	def scheduler_close
		close(true)
	end

	def close(internal = false)
		# $stderr.puts [__method__, Fiber.current].inspect

		unless internal
			if Fiber.scheduler == self
				return Fiber.set_scheduler(nil)
			end
		end

		if @closed
			raise "Scheduler already closed!"
		end

		self.run
	ensure
		if @urgent
			@urgent.each(&:close)
			@urgent = nil
		end

		@closed ||= true

		# We freeze to detect any unintended modifications after the scheduler is closed:
		self.freeze
	end

	def closed?
		@closed
	end

	def current_time
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end

	def timeout_after(duration, klass, message, &block)
		fiber = Fiber.current

		self.fiber do
			sleep(duration)

			if fiber&.alive?
				fiber.raise(klass, message)
			end
		end

		begin
			yield(duration)
		ensure
			fiber = nil
		end
	end

	def process_wait(pid, flags)
		# $stderr.puts [__method__, pid, flags, Fiber.current].inspect

		# This is a very simple way to implement a non-blocking wait:
		Thread.new do
			Process::Status.wait(pid, flags)
		end.value
	end

	def io_wait(io, events, duration)
		# $stderr.puts [__method__, io, events, duration, Fiber.current].inspect

		fiber = Fiber.current

		unless (events & IO::READABLE).zero?
			@readable[io] = fiber
			readable = true
		end

		unless (events & IO::WRITABLE).zero?
			@writable[io] = fiber
			writable = true
		end

		if duration
			@waiting[fiber] = current_time + duration
		end

		Fiber.yield
	ensure
		# Remove from @waiting in the case event occurred before the timeout expired:
		@waiting.delete(fiber) if duration
		@readable.delete(io) if readable
		@writable.delete(io) if writable
	end

	def io_select(*arguments)
		# Emulate the operation using a non-blocking thread:
		Thread.new do
			IO.select(*arguments)
		end.value
	end

	# Used for Kernel#sleep and Thread::Mutex#sleep
	def kernel_sleep(duration = nil)
		# $stderr.puts [__method__, duration, Fiber.current].inspect

		self.block(:sleep, duration)

		return true
	end

	# Used when blocking on synchronization (Thread::Mutex#lock,
	# Thread::Queue#pop, Thread::SizedQueue#push, ...)
	def block(blocker, timeout = nil)
		# $stderr.puts [__method__, blocker, timeout].inspect

		fiber = Fiber.current

		if timeout
			@waiting[fiber] = current_time + timeout
			begin
				Fiber.yield
			ensure
				# Remove from @waiting in the case #unblock was called before the timeout expired:
				@waiting.delete(fiber)
			end
		else
			@blocking[fiber] = true
			begin
				Fiber.yield
			ensure
				@blocking.delete(fiber)
			end
		end
	end

	# Used when synchronization wakes up a previously-blocked fiber
	# (Thread::Mutex#unlock, Thread::Queue#push, ...).
	# This might be called from another thread.
	def unblock(blocker, fiber)
		# $stderr.puts [__method__, blocker, fiber].inspect
		# $stderr.puts blocker.backtrace.inspect
		# $stderr.puts fiber.backtrace.inspect

		@lock.synchronize do
			@ready << fiber
		end

		io = @urgent.last
		io.write_nonblock('.')
	end

	def fiber(&block)
		fiber = Fiber.new(blocking: false, &block)

		fiber.resume

		return fiber
	end

	def address_resolve(hostname)
		Thread.new do
			Addrinfo.getaddrinfo(hostname, nil).map(&:ip_address).uniq
		end.value
	end
end
end

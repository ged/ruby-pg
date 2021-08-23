# -*- ruby -*-
# frozen_string_literal: true

require 'pg' unless defined?( PG )
require 'uri'
require 'io/wait'

# The PostgreSQL connection class. The interface for this class is based on
# {libpq}[http://www.postgresql.org/docs/9.2/interactive/libpq.html], the C
# application programmer's interface to PostgreSQL. Some familiarity with libpq
# is recommended, but not necessary.
#
# For example, to send query to the database on the localhost:
#
#    require 'pg'
#    conn = PG::Connection.open(:dbname => 'test')
#    res = conn.exec_params('SELECT $1 AS a, $2 AS b, $3 AS c', [1, 2, nil])
#    # Equivalent to:
#    #  res  = conn.exec('SELECT 1 AS a, 2 AS b, NULL AS c')
#
# See the PG::Result class for information on working with the results of a query.
#
class PG::Connection

	# The order the options are passed to the ::connect method.
	CONNECT_ARGUMENT_ORDER = %w[host port options tty dbname user password]


	### Quote the given +value+ for use in a connection-parameter string.
	def self::quote_connstr( value )
		return "'" + value.to_s.gsub( /[\\']/ ) {|m| '\\' + m } + "'"
	end


	### Parse the connection +args+ into a connection-parameter string. See PG::Connection.new
	### for valid arguments.
	def self::parse_connect_args( *args )
		return '' if args.empty?

		hash_arg = args.last.is_a?( Hash ) ? args.pop : {}
		option_string = ''
		options = {}

		# Parameter 'fallback_application_name' was introduced in PostgreSQL 9.0
		# together with PQescapeLiteral().
		if PG::Connection.instance_methods.find {|m| m.to_sym == :escape_literal }
			options[:fallback_application_name] = $0.sub( /^(.{30}).{4,}(.{30})$/ ){ $1+"..."+$2 }
		end

		if args.length == 1
			case args.first
			when URI, /\A#{URI::ABS_URI_REF}\z/
				uri = URI(args.first)
				options.merge!( Hash[URI.decode_www_form( uri.query )] ) if uri.query
			when /=/
				# Option string style
				option_string = args.first.to_s
			else
				# Positional parameters
				options[CONNECT_ARGUMENT_ORDER.first.to_sym] = args.first
			end
		else
			max = CONNECT_ARGUMENT_ORDER.length
			raise ArgumentError,
				"Extra positional parameter %d: %p" % [ max + 1, args[max] ] if args.length > max

			CONNECT_ARGUMENT_ORDER.zip( args ) do |(k,v)|
				options[ k.to_sym ] = v if v
			end
		end

		options.merge!( hash_arg )

		if uri
			uri.host     = nil if options[:host]
			uri.port     = nil if options[:port]
			uri.user     = nil if options[:user]
			uri.password = nil if options[:password]
			uri.path     = '' if options[:dbname]
			uri.query    = URI.encode_www_form( options )
			return uri.to_s.sub( /^#{uri.scheme}:(?!\/\/)/, "#{uri.scheme}://" )
		else
			option_string += ' ' unless option_string.empty? && options.empty?
			return option_string + options.map { |k,v| "#{k}=#{quote_connstr(v)}" }.join( ' ' )
		end
	end


	#  call-seq:
	#     conn.copy_data( sql [, coder] ) {|sql_result| ... } -> PG::Result
	#
	# Execute a copy process for transferring data to or from the server.
	#
	# This issues the SQL COPY command via #exec. The response to this
	# (if there is no error in the command) is a PG::Result object that
	# is passed to the block, bearing a status code of PGRES_COPY_OUT or
	# PGRES_COPY_IN (depending on the specified copy direction).
	# The application should then use #put_copy_data or #get_copy_data
	# to receive or transmit data rows and should return from the block
	# when finished.
	#
	# #copy_data returns another PG::Result object when the data transfer
	# is complete. An exception is raised if some problem was encountered,
	# so it isn't required to make use of any of them.
	# At this point further SQL commands can be issued via #exec.
	# (It is not possible to execute other SQL commands using the same
	# connection while the COPY operation is in progress.)
	#
	# This method ensures, that the copy process is properly terminated
	# in case of client side or server side failures. Therefore, in case
	# of blocking mode of operation, #copy_data is preferred to raw calls
	# of #put_copy_data, #get_copy_data and #put_copy_end.
	#
	# _coder_ can be a PG::Coder derivation
	# (typically PG::TextEncoder::CopyRow or PG::TextDecoder::CopyRow).
	# This enables encoding of data fields given to #put_copy_data
	# or decoding of fields received by #get_copy_data.
	#
	# Example with CSV input format:
	#   conn.exec "create table my_table (a text,b text,c text,d text)"
	#   conn.copy_data "COPY my_table FROM STDIN CSV" do
	#     conn.put_copy_data "some,data,to,copy\n"
	#     conn.put_copy_data "more,data,to,copy\n"
	#   end
	# This creates +my_table+ and inserts two CSV rows.
	#
	# The same with text format encoder PG::TextEncoder::CopyRow
	# and Array input:
	#   enco = PG::TextEncoder::CopyRow.new
	#   conn.copy_data "COPY my_table FROM STDIN", enco do
	#     conn.put_copy_data ['some', 'data', 'to', 'copy']
	#     conn.put_copy_data ['more', 'data', 'to', 'copy']
	#   end
	#
	# Example with CSV output format:
	#   conn.copy_data "COPY my_table TO STDOUT CSV" do
	#     while row=conn.get_copy_data
	#       p row
	#     end
	#   end
	# This prints all rows of +my_table+ to stdout:
	#   "some,data,to,copy\n"
	#   "more,data,to,copy\n"
	#
	# The same with text format decoder PG::TextDecoder::CopyRow
	# and Array output:
	#   deco = PG::TextDecoder::CopyRow.new
	#   conn.copy_data "COPY my_table TO STDOUT", deco do
	#     while row=conn.get_copy_data
	#       p row
	#     end
	#   end
	# This receives all rows of +my_table+ as ruby array:
	#   ["some", "data", "to", "copy"]
	#   ["more", "data", "to", "copy"]

	def copy_data( sql, coder=nil )
		res = exec( sql )

		case res.result_status
		when PGRES_COPY_IN
			begin
				if coder
					old_coder = self.encoder_for_put_copy_data
					self.encoder_for_put_copy_data = coder
				end
				yield res
			rescue Exception => err
				errmsg = "%s while copy data: %s" % [ err.class.name, err.message ]
				put_copy_end( errmsg )
				get_result
				raise
			else
				put_copy_end
				get_last_result
			ensure
				self.encoder_for_put_copy_data = old_coder if coder
			end

		when PGRES_COPY_OUT
			begin
				if coder
					old_coder = self.decoder_for_get_copy_data
					self.decoder_for_get_copy_data = coder
				end
				yield res
			rescue Exception => err
				cancel
				while get_copy_data
				end
				while get_result
				end
				raise
			else
				res = get_last_result
				if !res || res.result_status != PGRES_COMMAND_OK
					while get_copy_data
					end
					while get_result
					end
					raise PG::NotAllCopyDataRetrieved, "Not all COPY data retrieved"
				end
				res
			ensure
				self.decoder_for_get_copy_data = old_coder if coder
			end

		else
			raise ArgumentError, "SQL command is no COPY statement: #{sql}"
		end
	end

	# Backward-compatibility aliases for stuff that's moved into PG.
	class << self
		define_method( :isthreadsafe, &PG.method(:isthreadsafe) )
	end

	#
	# call-seq:
	#    conn.transaction { |conn| ... } -> result of the block
	#
	# Executes a +BEGIN+ at the start of the block,
	# and a +COMMIT+ at the end of the block, or
	# +ROLLBACK+ if any exception occurs.
	def transaction
		exec "BEGIN"
		res = yield(self)
	rescue Exception
		cancel if transaction_status != PG::PQTRANS_IDLE
		block
		exec "ROLLBACK"
		raise
	else
		exec "COMMIT"
		res
	end

	### Returns an array of Hashes with connection defaults. See ::conndefaults
	### for details.
	def conndefaults
		return self.class.conndefaults
	end

	### Return the Postgres connection defaults structure as a Hash keyed by option
	### keyword (as a Symbol).
	###
	### See also #conndefaults
	def self.conndefaults_hash
		return self.conndefaults.each_with_object({}) do |info, hash|
			hash[ info[:keyword].to_sym ] = info[:val]
		end
	end

	### Returns a Hash with connection defaults. See ::conndefaults_hash
	### for details.
	def conndefaults_hash
		return self.class.conndefaults_hash
	end

	### Return the Postgres connection info structure as a Hash keyed by option
	### keyword (as a Symbol).
	###
	### See also #conninfo
	def conninfo_hash
		return self.conninfo.each_with_object({}) do |info, hash|
			hash[ info[:keyword].to_sym ] = info[:val]
		end
	end

	# Method 'ssl_attribute' was introduced in PostgreSQL 9.5.
	if self.instance_methods.find{|m| m.to_sym == :ssl_attribute }
		# call-seq:
		#   conn.ssl_attributes -> Hash<String,String>
		#
		# Returns SSL-related information about the connection as key/value pairs
		#
		# The available attributes varies depending on the SSL library being used,
		# and the type of connection.
		#
		# See also #ssl_attribute
		def ssl_attributes
			ssl_attribute_names.each.with_object({}) do |n,h|
				h[n] = ssl_attribute(n)
			end
		end
	end

	private def wait_for_flush
		# From https://www.postgresql.org/docs/13/libpq-async.html
		# After sending any command or data on a nonblocking connection, call PQflush. If it returns 1, wait for the socket to become read- or write-ready. If it becomes write-ready, call PQflush again. If it becomes read-ready, call PQconsumeInput , then call PQflush again. Repeat until PQflush returns 0. (It is necessary to check for read-ready and drain the input with PQconsumeInput , because the server can block trying to send us data, e.g., NOTICE messages, and won't read our data until we read its.) Once PQflush returns 0, wait for the socket to be read-ready and then read the response as described above.

		until flush()
			# wait for the socket to become read- or write-ready

			if Fiber.respond_to?(:scheduler) && Fiber.scheduler
				# If a scheduler is set use it directly.
				# This is necessary since IO.select isn't passed to the scheduler.
				events = Fiber.scheduler.io_wait(socket_io, IO::READABLE | IO::WRITABLE, nil)
				if (events & IO::READABLE) > 0
					consume_input
				end
			else
				readable, writable = IO.select([socket_io], [socket_io])
				if readable.any?
					consume_input
				end
			end
		end
	end

	def async_exec(*args)
		discard_results
		async_send_query(*args)

		block()
		res = get_last_result

		if block_given?
			begin
				return yield(res)
			ensure
				res.clear
			end
		end
		res
	end

	def async_exec_params(*args)
		discard_results

		if args[1].nil?
			# TODO: pg_deprecated(3, ("forwarding async_exec_params to async_exec is deprecated"));
			async_send_query(*args)
		else
			async_send_query_params(*args)
		end

		block()
		res = get_last_result

		if block_given?
			begin
				return yield(res)
			ensure
				res.clear
			end
		end
		res
	end

	alias sync_send_query send_query
	def async_send_query(*args, &block)
		sync_send_query(*args)
		wait_for_flush
	end

	alias sync_send_query_params send_query_params
	def async_send_query_params(*args, &block)
		sync_send_query_params(*args)
		wait_for_flush
	end

	# In async_api=false mode all send calls run directly on libpq.
	# Blocking vs. nonblocking state can be changed in libpq.
	alias sync_setnonblocking setnonblocking

	# In async_api=true mode (default) all send calls run nonblocking.
	# The difference is that setnonblocking(true) disables automatic handling of would-block cases.
	def async_setnonblocking(enabled)
		singleton_class.async_send_api = !enabled
		sync_setnonblocking(true)
	end

	# sync/async isnonblocking methods are switched by async_setnonblocking()
	alias sync_isnonblocking isnonblocking
	def async_isnonblocking
		false
	end


	class << self
		alias sync_connect new

		def async_connect(*args, **kwargs)
			conn = PG::Connection.connect_start( *args, **kwargs ) or
				raise(PG::Error, "Unable to create a new connection")
			raise(PG::ConnectionBad, conn.error_message) if conn.status == PG::CONNECTION_BAD

			# Now grab a reference to the underlying socket so we know when the connection is established
			socket = conn.socket_io

			# Track the progress of the connection, waiting for the socket to become readable/writable before polling it
			poll_status = PG::PGRES_POLLING_WRITING
			until poll_status == PG::PGRES_POLLING_OK ||
					poll_status == PG::PGRES_POLLING_FAILED

				# If the socket needs to read, wait 'til it becomes readable to poll again
				case poll_status
				when PG::PGRES_POLLING_READING
					socket.wait_readable

				# ...and the same for when the socket needs to write
				when PG::PGRES_POLLING_WRITING
					socket.wait_writable
				end

				# Check to see if it's finished or failed yet
				poll_status = conn.connect_poll
			end

			raise(PG::ConnectionBad, conn.error_message) unless conn.status == PG::CONNECTION_OK

			# Set connection to nonblocking to handle all blocking states in ruby.
			# That way a fiber scheduler is able to handle IO requests.
			conn.sync_setnonblocking(true)
			conn.set_default_encoding

			conn
		end

		REDIRECT_CLASS_METHODS = {
			:new => [:async_connect, :sync_connect],
		}

		REDIRECT_SEND_METHODS = {
			:send_query => [:async_send_query, :sync_send_query],
			:send_query_params => [:async_send_query_params, :sync_send_query_params],
			:isnonblocking => [:async_isnonblocking, :sync_isnonblocking],
			:nonblocking? => [:async_isnonblocking, :sync_isnonblocking],
		}
		REDIRECT_METHODS = {
			:exec => [:async_exec, :sync_exec],
			:query => [:async_exec, :sync_exec],
			:exec_params => [:async_exec_params, :sync_exec_params],
			:prepare => [:async_prepare, :sync_prepare],
			:exec_prepared => [:async_exec_prepared, :sync_exec_prepared],
			:describe_portal => [:async_describe_portal, :sync_describe_portal],
			:describe_prepared => [:async_describe_prepared, :sync_describe_prepared],
			:setnonblocking => [:async_setnonblocking, :sync_setnonblocking],
		}

		def async_send_api=(enable)
			REDIRECT_SEND_METHODS.each do |ali, (async, sync)|
				undef_method(ali) if method_defined?(ali)
				alias_method( ali, enable ? async : sync )
			end
		end

		def async_api=(enable)
			self.async_send_api = enable
			REDIRECT_METHODS.each do |ali, (async, sync)|
				remove_method(ali) if method_defined?(ali)
				alias_method( ali, enable ? async : sync )
			end
			REDIRECT_CLASS_METHODS.each do |ali, (async, sync)|
				singleton_class.remove_method(ali) if method_defined?(ali)
				# TODO: send is necessary for ruby < 2.5
				singleton_class.send(:alias_method, ali, enable ? async : sync )
			end
		end
	end

	# pg-1.1.0+ defaults to libpq's async API for query related blocking methods
	self.async_api = true
end # class PG::Connection

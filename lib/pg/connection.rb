#!/usr/bin/env ruby

require 'pg' unless defined?( PG )

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

		# This will be swapped soon for code that makes options like those required for
		# PQconnectdbParams()/PQconnectStartParams(). For now, stick to an options string for
		# PQconnectdb()/PQconnectStart().

		# Parameter 'fallback_application_name' was introduced in PostgreSQL 9.0
		# together with PQescapeLiteral().
		if PG::Connection.instance_methods.find{|m| m.to_sym == :escape_literal }
			appname = $0.sub(/^(.{30}).{4,}(.{30})$/){ $1+"..."+$2 }
			appname = PG::Connection.quote_connstr( appname )
			connopts = ["fallback_application_name=#{appname}"]
		else
			connopts = []
		end

		# Handle an options hash first
		if args.last.is_a?( Hash )
			opthash = args.pop
			opthash.each do |key, val|
				connopts.push( "%s=%s" % [key, PG::Connection.quote_connstr(val)] )
			end
		end

		# Option string style
		if args.length == 1 && args.first.to_s.index( '=' )
			connopts.unshift( args.first )

		# Append positional parameters
		else
			args.each_with_index do |val, i|
				next unless val # Skip nil placeholders

				key = CONNECT_ARGUMENT_ORDER[ i ] or
					raise ArgumentError, "Extra positional parameter %d: %p" % [ i+1, val ]
				connopts.push( "%s=%s" % [key, PG::Connection.quote_connstr(val.to_s)] )
			end
		end

		return connopts.join(' ')
	end

	#  call-seq:
	#     conn.copy_data( sql ) {|sql_result| ... } -> PG::Result
	#
	# Execute a copy process for transfering data to or from the server.
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
	# Example with CSV input format:
	#   conn.exec "create table my_table (a text,b text,c text,d text,e text)"
	#   conn.copy_data "COPY my_table FROM STDOUT CSV" do
	#     conn.put_copy_data "some,csv,data,to,copy\n"
	#     conn.put_copy_data "more,csv,data,to,copy\n"
	#   end
	# This creates +my_table+ and inserts two rows.
	#
	# Example with CSV output format:
	#   conn.copy_data "COPY my_table TO STDOUT CSV" do
	#     while row=conn.get_copy_data
	#       p row
	#     end
	#   end
	# This prints all rows of +my_table+ to stdout:
	#   "some,csv,data,to,copy\n"
	#   "more,csv,data,to,copy\n"
	def copy_data( sql )
		res = exec( sql )

		case res.result_status
		when PGRES_COPY_IN
			begin
				yield res
			rescue Exception => err
				errmsg = "%s while copy data: %s" % [ err.class.name, err.message ]
				put_copy_end( errmsg )
				get_result
				raise
			else
				put_copy_end
				get_last_result
			end

		when PGRES_COPY_OUT
			begin
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
				if res.result_status != PGRES_COMMAND_OK
					while get_copy_data
					end
					while get_result
					end
					raise PG::NotAllCopyDataRetrieved, "Not all COPY data retrieved"
				end
				res
			end

		else
			raise ArgumentError, "SQL command is no COPY statement: #{sql}"
		end
	end

	# Backward-compatibility aliases for stuff that's moved into PG.
	class << self
		define_method( :isthreadsafe, &PG.method(:isthreadsafe) )
	end


	### Returns an array of Hashes with connection defaults. See ::conndefaults
	### for details.
	def conndefaults
		return self.class.conndefaults
	end

end # class PG::Connection

# Backward-compatible alias
PGconn = PG::Connection


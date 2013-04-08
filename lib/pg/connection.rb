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


	# Backward-compatibility aliases for stuff that's moved into PG.
	class << self
		define_method( :isthreadsafe, &PG.method(:isthreadsafe) )
	end
end # class PG::Connection

# Backward-compatible alias
PGconn = PG::Connection


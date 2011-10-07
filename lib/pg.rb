#!/usr/bin/env ruby

begin
	require 'pg_ext'
rescue LoadError
	# If it's a Windows binary gem, try the <major>.<minor> subdirectory
	if RUBY_PLATFORM =~/(mswin|mingw)/i
		major_minor = RUBY_VERSION[ /^(\d+\.\d+)/ ] or
			raise "Oops, can't extract the major/minor version from #{RUBY_VERSION.dump}"
		require "#{major_minor}/pg_ext"
	else
		raise
	end

end

#--
# The PG connection class.
class PGconn

	# The order the options are passed to the ::connect method.
	CONNECT_ARGUMENT_ORDER = %w[host port options tty dbname user password]


	### Quote the given +value+ for use in a connection-parameter string.
	def self::quote_connstr( value )
		return "'" + value.to_s.gsub( /[\\']/ ) {|m| '\\' + m } + "'"
	end


	### Parse the connection +args+ into a connection-parameter string. See PGconn.new
	### for valid arguments.
	def self::parse_connect_args( *args )
		return '' if args.empty?

		# This will be swapped soon for code that makes options like those required for
		# PQconnectdbParams()/PQconnectStartParams(). For now, stick to an options string for
		# PQconnectdb()/PQconnectStart().
		connopts = []

		# Handle an options hash first
		if args.last.is_a?( Hash )
			opthash = args.pop 
			opthash.each do |key, val|
				connopts.push( "%s=%s" % [key, PGconn.quote_connstr(val)] )
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
				connopts.push( "%s=%s" % [key, PGconn.quote_connstr(val.to_s)] )
			end
		end

		return connopts.join(' ')
	end

end # class PGconn



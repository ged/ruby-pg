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


# The top-level PG namespace.
module PG

	# Library version
	VERSION = '0.17.1'

	# VCS revision
	REVISION = %q$Revision$

	class NotAllCopyDataRetrieved < PG::Error
	end

	### Get the PG library version. If +include_buildnum+ is +true+, include the build ID.
	def self::version_string( include_buildnum=false )
		vstring = "%s %s" % [ self.name, VERSION ]
		vstring << " (build %s)" % [ REVISION[/: ([[:xdigit:]]+)/, 1] || '0' ] if include_buildnum
		return vstring
	end


	### Convenience alias for PG::Connection.new.
	def self::connect( *args )
		return PG::Connection.new( *args )
	end


	require 'pg/exceptions'
	require 'pg/constants'
	require 'pg/simple_type'
	require 'pg/text_encoder'
	require 'pg/text_decoder'
	require 'pg/basic_type_mapping'
	require 'pg/column_mapping'
	require 'pg/connection'
	require 'pg/result'

end # module PG


# Backward-compatible aliase
PGError = PG::Error


#!/usr/bin/env ruby

require 'rbconfig'

# Load the correct version if it's a Windows binary gem
if RUBY_PLATFORM =~/(mswin|mingw)/i
	major_minor = RUBY_VERSION[ /^(\d+\.\d+)/ ] or
		raise "Oops, can't extract the major/minor version from #{RUBY_VERSION.dump}"

	begin
		require "#{major_minor}/pg_ext"
	rescue LoadError
		require 'pg_ext'
	end
else
	require 'pg_ext'
end


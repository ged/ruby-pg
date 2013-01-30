#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::Result

	### Returns all tuples as an array of arrays
	def values
		return enum_for(:each_row).to_a
	end

end # class PG::Result

# Backward-compatible alias
PGresult = PG::Result

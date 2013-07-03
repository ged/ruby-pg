#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::Result

	### Returns all tuples as an array of arrays
	def values
		return enum_for(:each_row).to_a
	end

	def map_types!(oid_mapping, default_mapping=nil)
		types = nfields.times.map{|i| oid_mapping[ftype(i)] || default_mapping }
		self.column_mapping = PG::ColumnMapping.new( types )
		self
	end

end # class PG::Result

# Backward-compatible alias
PGresult = PG::Result

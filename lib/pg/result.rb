#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::Result

	### Returns all tuples as an array of arrays
	def values
		return enum_for(:each_row).to_a
	end

	# Build and apply a ColumnMapping based on the given OID-to-Type Mapping.
	#
	# +oid_mapping+: an optional Object that responds to column_mapping_for_result(result) .
	#   This method should build and return a PG::ColumnMapping object suitable
	#   for the given result.
	#
	# See PG::BasicTypeMapping
	def map_types!(oid_mapping = PG:: BasicTypeMapping)
		self.column_mapping = oid_mapping
		self
	end

end # class PG::Result

# Backward-compatible alias
PGresult = PG::Result

#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::Result

	### Returns all tuples as an array of arrays
	def values
		return enum_for(:each_row).to_a
	end

	DEFAULT_OID_MAP_TEXT = {
		16 => PG::ColumnMapping::TextBoolean, # BOOLEAN
		17 => PG::ColumnMapping::TextBytea, # BYTEA
		20 => PG::ColumnMapping::TextInteger, # INT8
		21 => PG::ColumnMapping::TextInteger, # INT2
		23 => PG::ColumnMapping::TextInteger, # INT4
		700 => PG::ColumnMapping::TextFloat, # FLOAT4
		701 => PG::ColumnMapping::TextFloat, # FLOAT8
		705 => PG::ColumnMapping::TextString, # TEXT
		1082 => proc{|res, tuple, field, string| Time.new(string) }, # DATE
		1114 => proc{|res, tuple, field, string| Time.new(string) }, # TIMESTAMP WITHOUT TIME ZONE
		1184 => proc{|res, tuple, field, string| Time.new(string) }, # TIMESTAMP WITH TIME ZONE
	}

	DEFAULT_OID_MAP_BINARY = {
		16 => PG::ColumnMapping::BinaryBoolean, # BOOLEAN
		17 => PG::ColumnMapping::BinaryBytea, # BYTEA
		20 => PG::ColumnMapping::BinaryInteger, # INT8
		21 => PG::ColumnMapping::BinaryInteger, # INT2
		23 => PG::ColumnMapping::BinaryInteger, # INT4
		700 => PG::ColumnMapping::BinaryFloat, # FLOAT4
		701 => PG::ColumnMapping::BinaryFloat, # FLOAT8
		705 => PG::ColumnMapping::BinaryString, # TEXT
	}

	DEFAULT_OID_MAP = [DEFAULT_OID_MAP_TEXT, DEFAULT_OID_MAP_BINARY]

	# Build and set a ColumnMapping based on the given OID-to-Type Mapping.
	#
	# +oid_mapping+: a Hash with OIDs (Integer) as keys and with the corresponding
	#   type convertion as value part. The type convertion must be suitable
	#   as a parameter to PG::ColumnMapping.new().
	#
	# +default_mapping+: the type conversion that is used, when the given OID is not
	#   in +oid_mapping+.
	#
	# Both +oid_mapping+ and +default_mapping+ can also be wrapped in an Array
	# with element 0 for mappings of text format and element 1 for binary
	# format.
	def map_types!(oid_mapping = DEFAULT_OID_MAP, default_mapping=nil)
		types = nfields.times.map{|i|
			(oid_mapping.kind_of?(Array) ? oid_mapping[fformat(i)][ftype(i)] : oid_mapping[ftype(i)]) ||
			(default_mapping.kind_of?(Array) ? default_mapping[fformat(i)] : default_mapping)
		}
		self.column_mapping = PG::ColumnMapping.new( types )
		self
	end

end # class PG::Result

# Backward-compatible alias
PGresult = PG::Result

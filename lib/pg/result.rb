#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::Result

	### Returns all tuples as an array of arrays
	def values
		return enum_for(:each_row).to_a
	end

	DEFAULT_OID_MAP_TEXT = {
		16 => PG::Type::TextBoolean, # BOOLEAN
		17 => PG::Type::TextBytea, # BYTEA
		20 => PG::Type::TextInteger, # INT8
		21 => PG::Type::TextInteger, # INT2
		23 => PG::Type::TextInteger, # INT4
		700 => PG::Type::TextFloat, # FLOAT4
		701 => PG::Type::TextFloat, # FLOAT8
		705 => PG::Type::TextString, # TEXT
		1082 => PG::Type::TextTime, # DATE
		1114 => PG::Type::TextTime, # TIMESTAMP WITHOUT TIME ZONE
		1184 => PG::Type::TextTime, # TIMESTAMP WITH TIME ZONE
	}

	DEFAULT_OID_MAP_BINARY = {
		16 => PG::Type::BinaryBoolean, # BOOLEAN
		17 => PG::Type::BinaryBytea, # BYTEA
		20 => PG::Type::BinaryInteger, # INT8
		21 => PG::Type::BinaryInteger, # INT2
		23 => PG::Type::BinaryInteger, # INT4
		700 => PG::Type::BinaryFloat, # FLOAT4
		701 => PG::Type::BinaryFloat, # FLOAT8
		705 => PG::Type::BinaryString, # TEXT
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

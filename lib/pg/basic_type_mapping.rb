#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::BasicTypeMapping
	ValidFormats = { 0 => true, 1 => true }

	attr_reader :connection
	attr_reader :text_types
	attr_reader :binary_types

	def initialize(connection)
		@connection = connection
		@types = build_types
		@text_types = @types[0].freeze
		@binary_types = @types[1].freeze

		@types_by_name = types_by_name
		@types_by_oid = types_by_oid
		@types_by_value = types_by_value
		@array_types_by_value = array_types_by_value
	end

	def type_by_name(format, name)
		check_format(format)
		@types_by_name[format][name]
	end

	def type_by_oid(format, oid)
		check_format(format)
		@types_by_oid[format][oid]
	end

	def type_by_value(value)
		map = @types_by_value
		while value.kind_of?(Array)
			value = value.first
			map = @array_types_by_value
		end
		map[value.class]
	end

	private
	def check_format(format)
		raise(ArgumentError, "Invalid format value %p" % format) unless ValidFormats[format]
	end

	def types_by_oid
		@types.map{|f| f.inject({}){|h, t| h[t.oid] = t; h } }
	end

	def types_by_name
		@types.map{|f| f.inject({}){|h, t| h[t.name] = t; h } }
	end

	def types_by_value
		DEFAULT_TYPE_MAP.inject({}) do |h, (klass, (format, name))|
			h[klass] = type_by_name(format, name)
			h
		end
	end

	def array_types_by_value
		DEFAULT_ARRAY_TYPE_MAP.inject({}) do |h, (klass, (format, name))|
			h[klass] = type_by_name(format, name)
			h
		end
	end

	DEFAULT_TYPE_MAP = {
		TrueClass => [1, 'bool'],
		FalseClass => [1, 'bool'],
		Time => [0, 'timestamptz'],
		Fixnum => [1, 'int8'],
		Bignum => [1, 'int8'],
		String => [0, 'text'],
		Float => [0, 'float8'],
	}

	DEFAULT_ARRAY_TYPE_MAP = {
		Time => [0, '_timestamptz'],
		Fixnum => [0, '_int8'],
		Bignum => [0, '_int8'],
		String => [0, '_text'],
		Float => [0, '_float8'],
	}


	def supports_ranges?
		@connection.server_version >= 90200
	end

	def build_types
		type_map = [{}, {}]
		text_type_map = type_map[0]

		if supports_ranges?
			result = @connection.exec <<-SQL
				SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput, r.rngsubtype
				FROM pg_type as t
				LEFT JOIN pg_range as r ON oid = rngtypid
			SQL
		else
			result = @connection.exec <<-SQL
				SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput
				FROM pg_type as t
			SQL
		end
		ranges, nodes = result.partition { |row| row['typinput'] == 'range_in' }
		leaves, nodes = nodes.partition { |row| row['typelem'] == '0' }
		arrays, nodes = nodes.partition { |row| row['typinput'] == 'array_in' }

		# populate the enum types
		enums, leaves = leaves.partition { |row| row['typinput'] == 'enum_in' }
# 		enums.each do |row|
# 			type_map[row['oid'].to_i] = OID::Enum.new
# 		end

		# populate the base types
		leaves.find_all { |row| self.class.registered_type? 0, row['typname'] }.each do |row|
			type = NAMES[0][row['typname']].dup
			type.oid = row['oid'].to_i
			type.name = row['typname']
			text_type_map[type.oid] = type
		end

		records_by_oid = result.group_by { |row| row['oid'] }

		# populate composite types
# 		nodes.each do |row|
# 			add_oid row, records_by_oid, type_map
# 		end

		# populate array types
		arrays.each do |row|
			elements_type = text_type_map[row['typelem'].to_i]
			next unless elements_type

			type = PG::CompositeType.new encoder: PG::TextEncoder::ARRAY, decoder: PG::TextDecoder::ARRAY
			type.oid = row['oid'].to_i
			type.name = row['typname']
			type.format = 0
			type.elements_type = elements_type
			type.needs_quotation = !DONT_QUOTE_TYPES[row['typelem']]
			text_type_map[type.oid] = type
		end

		# populate range types
# 		ranges.find_all { |row| type_map.key? row['rngsubtype'].to_i }.each do |row|
# 			subtype = type_map[row['rngsubtype'].to_i]
# 			range = OID::Range.new subtype
# 			type_map[row['oid'].to_i] = range
# 		end

		binary_type_map = type_map[1]

		# populate the base types
		leaves.find_all { |row| self.class.registered_type? 1, row['typname'] }.each do |row|
			type = NAMES[1][row['typname']].dup
			type.oid = row['oid'].to_i
			type.name = row['typname']
			binary_type_map[type.oid] = type
		end

		type_map.map(&:values)
	end

	# Hash of text types that don't require quotation, when used within composite types.
	#   type.name => true
	DONT_QUOTE_TYPES = %w[
		int2 int4 int8
		float4 float8
		oid
	].inject({}){|h,e| h[e] = true; h }

	# The key of this hash maps to the `typname` column from the table.
	# type_map is then dynamically built with oids as the key and type
	# objects as values.
	NAMES = [{}, {}]

	# Register an OID type named +name+ with a typecasting object in
	# +type+.  +name+ should correspond to the `typname` column in
	# the `pg_type` table.
	def self.register_type(format, name, encoder, decoder)
		type = PG::SimpleType.new name: name, encoder: encoder, decoder: decoder, format: format
		NAMES[format][name] = type
	end

	# Alias the +old+ type to the +new+ type.
	def self.alias_type(format, new, old)
		NAMES[format][new] = NAMES[format][old]
	end

	# Is +name+ a registered type?
	def self.registered_type?(format, name)
		NAMES[format].key? name
	end

	register_type 0, 'int2', PG::TextEncoder::INTEGER, PG::TextDecoder::INTEGER
	alias_type    0, 'int4', 'int2'
	alias_type    0, 'int8', 'int2'
	alias_type    0, 'oid',  'int2'

# 	register_type 0, 'numeric', OID::Decimal.new
	register_type 0, 'text', PG::TextEncoder::STRING, PG::TextDecoder::STRING
	alias_type 0, 'varchar', 'text'
	alias_type 0, 'char', 'text'
	alias_type 0, 'bpchar', 'text'
	alias_type 0, 'xml', 'text'

# 	# FIXME: why are we keeping these types as strings?
# 	alias_type 'tsvector', 'text'
# 	alias_type 'interval', 'text'
# 	alias_type 'macaddr',  'text'
# 	alias_type 'uuid',     'text'
#
# 	register_type 'money', OID::Money.new
	register_type 0, 'bytea', PG::TextEncoder::BYTEA, PG::TextDecoder::BYTEA
	register_type 0, 'bool', PG::TextEncoder::BOOLEAN, PG::TextDecoder::BOOLEAN
# 	register_type 'bit', OID::Bit.new
# 	register_type 'varbit', OID::Bit.new
#
	register_type 0, 'float4', PG::TextEncoder::FLOAT, PG::TextDecoder::FLOAT
	alias_type 0, 'float8', 'float4'

	register_type 0, 'timestamp', PG::TextEncoder::TIMESTAMP_WITHOUT_TIME_ZONE, PG::TextDecoder::TIMESTAMP_WITHOUT_TIME_ZONE
	register_type 0, 'timestamptz', PG::TextEncoder::TIMESTAMP_WITH_TIME_ZONE, PG::TextDecoder::TIMESTAMP_WITH_TIME_ZONE
	register_type 0, 'date', PG::TextEncoder::DATE, PG::TextDecoder::DATE
# 	register_type 'time', OID::Time.new
#
# 	register_type 'path', OID::Text.new
# 	register_type 'point', OID::Point.new
# 	register_type 'polygon', OID::Text.new
# 	register_type 'circle', OID::Text.new
# 	register_type 'hstore', OID::Hstore.new
# 	register_type 'json', OID::Json.new
# 	register_type 'citext', OID::Text.new
# 	register_type 'ltree', OID::Text.new
#
# 	register_type 'cidr', OID::Cidr.new
# 	alias_type 'inet', 'cidr'



	register_type 1, 'int2', PG::BinaryEncoder::INT2, PG::BinaryDecoder::INTEGER
	register_type 1, 'int4', PG::BinaryEncoder::INT4, PG::BinaryDecoder::INTEGER
	register_type 1, 'int8', PG::BinaryEncoder::INT8, PG::BinaryDecoder::INTEGER
	alias_type    1, 'oid',  'int2'

	register_type 1, 'text', PG::BinaryEncoder::STRING, PG::BinaryDecoder::STRING
	alias_type 1, 'varchar', 'text'
	alias_type 1, 'char', 'text'
	alias_type 1, 'bpchar', 'text'
	alias_type 1, 'xml', 'text'

	register_type 1, 'bytea', PG::BinaryEncoder::BYTEA, PG::BinaryDecoder::BYTEA
	register_type 1, 'bool', PG::BinaryEncoder::BOOLEAN, PG::BinaryDecoder::BOOLEAN
	register_type 1, 'float4', nil, PG::BinaryDecoder::FLOAT
	register_type 1, 'float8', nil, PG::BinaryDecoder::FLOAT


	def column_mapping_for_query_params( params )
		types = params.map do |p|
			type_by_value(p)
		end
		PG::ColumnMapping.new types
	end

	def column_mapping_for_result( result )
		types = Array.new(result.nfields) do |i|
			@types_by_oid[result.fformat(i)][result.ftype(i)]
		end
		PG::ColumnMapping.new( types )
	end
end

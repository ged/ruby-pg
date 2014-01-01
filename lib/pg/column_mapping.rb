#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::ColumnMapping

	DEFAULT_TYPE_MAP_TEXT = {
		TrueClass => PG::Type::Binary::BOOLEAN,
		FalseClass => PG::Type::Binary::BOOLEAN,
		Time => PG::Type::Text::TIMESTAMP_WITH_TIME_ZONE,
		Fixnum => PG::Type::Binary::INT8,
		Bignum => PG::Type::Binary::INT8,
		String => PG::Type::Binary::TEXT,
		Float => PG::Type::Text::FLOAT8,
	}

	def self.for_query_params( params, type_mapping = DEFAULT_TYPE_MAP_TEXT, &default_mapping )
		types = params.map{|p| type_mapping[p.class] || (default_mapping && yield(p)) }
		PG::ColumnMapping.new types
	end

	DEFAULT_OID_MAP_TEXT = PG::Type::Text.constants.
		map{|s| PG::Type::Text.const_get(s) }.
		select{|c| c.respond_to?(:oid) }.
		inject({}){|h,c| h[c.oid] = c; h }

	DEFAULT_OID_MAP_BINARY = PG::Type::Binary.constants.
		map{|s| PG::Type::Binary.const_get(s) }.
		select{|c| c.respond_to?(:oid) }.
		inject({}){|h,c| h[c.oid] = c; h }

	DEFAULT_OID_MAP = [DEFAULT_OID_MAP_TEXT, DEFAULT_OID_MAP_BINARY]

	def self.for_result( result, oid_mapping = DEFAULT_OID_MAP, &default_mapping )
		types = result.nfields.times.map do |i|
			(oid_mapping.kind_of?(Array) ? oid_mapping[result.fformat(i)][result.ftype(i)] : oid_mapping[result.ftype(i)]) ||
			(default_mapping && yield(result, i))
		end
		PG::ColumnMapping.new( types )
	end

	def oids
		types.map{|c| c.oid if c }
	end

	def inspect
		type_strings = types.map{|c| c ? "#{c.name}:#{c.format}" : 'nil' }
		"#<PG::Type::CConverter #{type_strings.join(' ')}>"
	end
end # class PG::Result

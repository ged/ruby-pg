#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::BasicTypeMapping

	DEFAULT_TYPE_MAP_TEXT = {
		TrueClass => PG::Type::Binary::BOOLEAN,
		FalseClass => PG::Type::Binary::BOOLEAN,
		Time => PG::Type::Text::TIMESTAMP_WITH_TIME_ZONE,
		Fixnum => PG::Type::Binary::INT8,
		Bignum => PG::Type::Binary::INT8,
		String => PG::Type::Binary::TEXT,
		Float => PG::Type::Text::FLOAT8,
	}

	def self.column_mapping_for_query_params( params )
		types = params.map{|p| DEFAULT_TYPE_MAP_TEXT[p.class] }
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

	def self.column_mapping_for_result( result )
		types = result.nfields.times.map do |i|
			DEFAULT_OID_MAP[result.fformat(i)][result.ftype(i)]
		end
		PG::ColumnMapping.new( types )
	end
end

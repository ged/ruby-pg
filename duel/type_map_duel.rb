# frozen_string_literal: true

require_relative "duel_helper"

# The type maps that decode a result's values into Ruby objects: the
# basic ones, which pick a decoder by the column's type OID, and one of
# explicit decoders by column. Each decodes a result that's in memory
# already (see ROWS_SQL), so no round trip is timed.

setup do
	@conn = pg_connection
	@text = rows_result(@conn)
	@binary = rows_result(@conn, 1)
end
teardown { @conn.close }

duel "type map: BasicTypeMapForResults, text format" do
	once { @map = PG::BasicTypeMapForResults.new(@conn) }
	@text.map_types!(@map).values
end

duel "type map: BasicTypeMapForResults, binary format" do
	once { @map = PG::BasicTypeMapForResults.new(@conn) }
	@binary.map_types!(@map).values
end

duel "type map: TypeMapByColumn of text decoders" do
	once do
		@map = PG::TypeMapByColumn.new([
			PG::TextDecoder::Integer.new, nil, PG::TextDecoder::Float.new, PG::TextDecoder::Boolean.new,
			PG::TextDecoder::TimestampWithoutTimeZone.new, PG::TextDecoder::Date.new,
			PG::TextDecoder::Array.new(elements_type: PG::TextDecoder::Integer.new),
		])
	end
	@text.map_types!(@map).values
end

duel "type map: BasicTypeMapForQueries picks encoders for parameters" do
	once do
		@map = PG::BasicTypeMapForQueries.new(@conn)
		@params = [42, "jane@example.com", 3.5, true, nil, Time.utc(2026, 1, 2, 3, 4, 5), [1, 2, 3], %w[a b], 2**40]
	end
	@map.query_param_encoders(@params)
end

duel "type map: embed_params with a BasicTypeMapForQueries" do
	once do
		@map = PG::BasicTypeMapForQueries.new(@conn)
		@params = [42, "O'Brien", 3.5, true, nil, Time.utc(2026, 1, 2, 3, 4, 5), [1, 2, 3]]
	end
	@conn.embed_params("SELECT * FROM users WHERE id = $1 AND name = $2 AND score > $3 AND active = $4 " \
		"AND deleted_at IS $5 AND created_at < $6 AND group_id = ANY($7)", @params, type_map: @map)
end

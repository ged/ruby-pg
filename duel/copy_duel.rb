# frozen_string_literal: true

require_relative "duel_helper"

# COPY, the fast way in and out of a table, with the CopyRow coders: an
# encoder that turns each row (an Array) into a line, and a decoder that
# turns each line back. On their own first, then through the worker's
# server.

ROWS = Array.new(100) do |i|
	[i, "user #{i}", "line\twith a tab", i.even? ? nil : "O'Brien \\ #{i}", (i * 1.5).to_s]
end.freeze

duel "copy: encode 100 rows with TextEncoder::CopyRow" do
	once { @encoder = PG::TextEncoder::CopyRow.new }
	ROWS.each { |row| @encoder.encode(row) }
end

duel "copy: decode 100 lines with TextDecoder::CopyRow" do
	once do
		@decoder = PG::TextDecoder::CopyRow.new
		encoder = PG::TextEncoder::CopyRow.new
		@lines = ROWS.map { |row| encoder.encode(row) }
	end
	@lines.each { |line| @decoder.decode(line) }
end

copy_table = lambda do
	@conn = pg_connection
	@conn.exec("CREATE TEMP TABLE copied (id int, name text, note text, other text, score text)")
	columns = PG::TypeMapByColumn.new([PG::TextEncoder::Integer.new, nil, nil, nil, nil])
	@encoder = PG::TextEncoder::CopyRow.new(type_map: columns)
end

# Each iteration's rows are rolled back, so the table never grows.
rolled_back = lambda do |iteration|
	@conn.exec("BEGIN")
	iteration.call
	@conn.exec("ROLLBACK")
end

duel "copy: COPY 100 rows in with an encoder",
	setup: copy_table, teardown: -> { @conn.close }, around_iteration: rolled_back do
	@conn.copy_data("COPY copied FROM STDIN", @encoder) do
		ROWS.each { |row| @conn.put_copy_data(row) }
	end
end

copy_out = lambda do
	@conn = pg_connection
	columns = PG::TypeMapByColumn.new([PG::TextDecoder::Integer.new, nil, PG::TextDecoder::Float.new])
	@decoder = PG::TextDecoder::CopyRow.new(type_map: columns)
end

duel "copy: COPY 100 rows out with a decoder", setup: copy_out, teardown: -> { @conn.close } do
	@conn.copy_data("COPY (SELECT g, 'user ' || g, g * 1.5 FROM generate_series(1, 100) g) TO STDOUT", @decoder) do
		while @conn.get_copy_data; end
	end
end

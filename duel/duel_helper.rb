# frozen_string_literal: true

# What several files of benchmarks share: a connection to the worker's
# own PostgreSQL server (see .duel.rb), and results and values fetched
# once, so that what's timed is the driver's work on them.

# A new connection to the worker's server. A benchmark keeps one for all
# its samples.
def pg_connection
	PG.connect(Duel::PostgreSQL.url)
end

# A typical result's columns: an id, a name, a score, a flag, a
# timestamp, a date, and a small integer array, in 100 rows.
ROWS_SQL = <<~SQL
	SELECT g AS id, 'user' || g AS name, g * 1.5::float8 AS score, g % 2 = 0 AS active,
		timestamp '2026-01-01 12:00:00' + g * interval '1 minute 1.5 seconds' AS created_at,
		date '2026-01-01' + g AS day, ARRAY[g, g + 1, g + 2] AS tags
	FROM generate_series(1, 100) g
SQL

# ROWS_SQL's result, in text format (or with +format+ 1, binary), over
# +conn+. It stays in memory after +conn+ moves on, so reading it makes
# no round trip.
def rows_result(conn, format = 0)
	conn.exec_params(ROWS_SQL, [], format)
end

# The +i+th of the timestamps below, as the server sends it, with
# +suffix+ (a zone, say).
def timestamp_text(i, suffix = "")
	format("2026-%02d-%02d %02d:%02d:%02d.%06d%s",
		(i % 12) + 1, (i % 28) + 1, i % 24, i % 60, (i * 7) % 60, i * 1234, suffix)
end

# 100 fixed values of each kind that a text decoder takes, as the server
# sends them.
TEXT_VALUES = {
	integers: Array.new(100) { |i| (i * 7919).to_s },
	floats: Array.new(100) { |i| (i * 3.14159).to_s },
	timestamps: Array.new(100) { |i| timestamp_text(i) },
	timestamptzs: Array.new(100) { |i| timestamp_text(i, "+02") },
	dates: Array.new(100) { |i| format("2026-%02d-%02d", (i % 12) + 1, (i % 28) + 1) },
}.freeze

# Times to encode, fixed.
TIMES = Array.new(100) { |i| Time.utc(2026, (i % 12) + 1, (i % 28) + 1, i % 24, i % 60, (i * 7) % 60, i * 1234) }.freeze

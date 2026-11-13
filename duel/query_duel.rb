# frozen_string_literal: true

require_relative "duel_helper"

# Queries, over a Unix socket to the worker's own server: sending each
# one, waiting for its result and reading it. What the server does for
# them is in its own process, not this one's CPU time, so these are
# judged on what the driver does, and on the plugin's counts of the
# queries and rows the server ran.

setup { @conn = pg_connection }
teardown { @conn.close }

duel "query: exec a small SELECT" do
	@conn.exec("SELECT 1")
end

duel "query: exec_params with three parameters" do
	@conn.exec_params("SELECT $1::int, $2::text, $3::bool", [42, "jane@example.com", true])
end

duel "query: exec_prepared a statement" do
	once { @conn.prepare("user_by_id", "SELECT $1::int AS id, 'user' || $1 AS name") }
	@conn.exec_prepared("user_by_id", [42])
end

duel "query: exec 100 rows and read their values" do
	@conn.exec(ROWS_SQL).values
end

duel "query: exec_params with a BasicTypeMapForQueries" do
	once do
		@conn.type_map_for_queries = PG::BasicTypeMapForQueries.new(@conn)
		@params = [42, "jane@example.com", 3.5, true, Time.utc(2026, 1, 2, 3, 4, 5), [1, 2, 3]]
	end
	@conn.exec_params("SELECT $1, $2, $3, $4, $5, $6", @params)
end

duel "query: 100 rows decoded by a BasicTypeMapForResults" do
	once { @conn.type_map_for_results = PG::BasicTypeMapForResults.new(@conn) }
	@conn.exec(ROWS_SQL).values
end

# frozen_string_literal: true

require_relative "duel_helper"

# Quoting and escaping for SQL, which libpq does by the connection's
# encoding, and pg wraps: no round trip. Each escapes 20 fixed strings,
# some with quotes and backslashes in them.

setup do
	@conn = pg_connection
	@strings = Array.new(20) { |i| i.even? ? "jane#{i}@example.com" : "O'Brien \\ \"#{i}\" it's" }
end
teardown { @conn.close }

duel "escape: escape_string" do
	@strings.each { |string| @conn.escape_string(string) }
end

duel "escape: escape_literal" do
	@strings.each { |string| @conn.escape_literal(string) }
end

duel "escape: quote_ident of a schema-qualified name" do
	PG::Connection.quote_ident(%w[public users])
	PG::Connection.quote_ident("Order Items")
end

duel "escape: escape_bytea and unescape_bytea of 4 KB" do
	once { @bytes = (0...4096).map { |i| (i % 256).chr }.join.b }
	PG::Connection.unescape_bytea(@conn.escape_bytea(@bytes))
end

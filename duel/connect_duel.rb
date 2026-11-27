# frozen_string_literal: true

require_relative "duel_helper"

# What happens to the connection parameters before libpq connects: every
# PG.connect parses them, and a pool or an ORM builds them from a URL or a
# Hash. No connection is made.

duel "connect: parse_connect_args of a URL" do
	PG::Connection.parse_connect_args(
		"postgres://jane:secret@db.example.com:5433/app_production?sslmode=require&connect_timeout=5"
	)
end

duel "connect: parse_connect_args of a keyword string" do
	PG::Connection.parse_connect_args("host=db.example.com port=5433 dbname=app_production user=jane sslmode=require")
end

duel "connect: parse_connect_args of a Hash" do
	PG::Connection.parse_connect_args(host: "db.example.com", port: 5433, dbname: "app_production", user: "jane",
		password: "it's secret", sslmode: "require", application_name: "web")
end

duel "connect: conninfo_hash of a connection", setup: -> { @conn = pg_connection }, teardown: -> { @conn.close } do
	@conn.conninfo_hash
end

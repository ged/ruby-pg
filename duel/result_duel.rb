# frozen_string_literal: true

require_relative "duel_helper"

# Reading a result that's in memory already, 100 rows of 7 columns (see
# ROWS_SQL): what an application does with every result, once its query
# has come back.

setup do
	conn = pg_connection
	@result = rows_result(conn)
	@symbols = rows_result(conn).field_names_as(:symbol)
	conn.close
end

duel "result: values" do
	@result.values
end

duel "result: getvalue of every field" do
	result = @result
	100.times do |row|
		7.times { |field| result.getvalue(row, field) }
	end
end

duel "result: each, a Hash a row" do
	@result.each { |_row| nil }
end

duel "result: each_row, an Array a row" do
	@result.each_row { |_row| nil }
end

duel "result: column_values of two columns" do
	@result.column_values(0)
	@result.column_values(1)
end

duel "result: tuple, and fields by name" do
	result = @result
	100.times do |row|
		tuple = result.tuple(row)
		tuple["id"]
		tuple["name"]
		tuple[6]
	end
end

duel "result: each, a Hash a row with Symbol keys" do
	@symbols.each { |_row| nil }
end

duel "result: field names, numbers and types" do
	result = @result
	result.fields
	7.times do |field|
		result.fname(field)
		result.ftype(field)
		result.fmod(field)
	end
	result.fnumber("created_at")
	result.fnumber("tags")
end

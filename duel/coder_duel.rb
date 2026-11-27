# frozen_string_literal: true

require_relative "duel_helper"

# Encoders and decoders on their own, 100 fixed values a call, as a type
# map runs them on a column: the text format, which results come in by
# default, and the binary one.

duel "text decoder: Integer" do
	once { @decoder = PG::TextDecoder::Integer.new }
	TEXT_VALUES[:integers].each { |value| @decoder.decode(value) }
end

duel "text decoder: Float" do
	once { @decoder = PG::TextDecoder::Float.new }
	TEXT_VALUES[:floats].each { |value| @decoder.decode(value) }
end

duel "text decoder: TimestampWithoutTimeZone" do
	once { @decoder = PG::TextDecoder::TimestampWithoutTimeZone.new }
	TEXT_VALUES[:timestamps].each { |value| @decoder.decode(value) }
end

duel "text decoder: TimestampWithTimeZone" do
	once { @decoder = PG::TextDecoder::TimestampWithTimeZone.new }
	TEXT_VALUES[:timestamptzs].each { |value| @decoder.decode(value) }
end

duel "text decoder: Date" do
	once { @decoder = PG::TextDecoder::Date.new }
	TEXT_VALUES[:dates].each { |value| @decoder.decode(value) }
end

duel "text decoder: an Array of 100 integers" do
	once do
		@decoder = PG::TextDecoder::Array.new(elements_type: PG::TextDecoder::Integer.new)
		@array = "{#{TEXT_VALUES[:integers].join(',')}}"
	end
	@decoder.decode(@array)
end

duel "text decoder: an Array of quoted strings, nested" do
	once do
		@decoder = PG::TextDecoder::Array.new(elements_type: PG::TextDecoder::String.new)
		row = Array.new(10) { |i| %("name \\"#{i}\\", with, commas") }.join(",")
		@array = "{#{Array.new(10) { "{#{row}}" }.join(',')}}"
	end
	@decoder.decode(@array)
end

duel "text decoder: Bytea of 4 KB" do
	once do
		@decoder = PG::TextDecoder::Bytea.new
		@hex = "\\x#{(0...4096).map { |i| format('%02x', i % 256) }.join}"
	end
	@decoder.decode(@hex)
end

duel "text encoder: Integer" do
	once do
		@encoder = PG::TextEncoder::Integer.new
		@integers = TEXT_VALUES[:integers].map(&:to_i)
	end
	@integers.each { |value| @encoder.encode(value) }
end

duel "text encoder: TimestampWithTimeZone" do
	once { @encoder = PG::TextEncoder::TimestampWithTimeZone.new }
	TIMES.each { |value| @encoder.encode(value) }
end

duel "text encoder: an Array of strings that need quoting" do
	once do
		@encoder = PG::TextEncoder::Array.new(elements_type: PG::TextEncoder::String.new)
		@array = Array.new(10) { |i| Array.new(10) { |j| %(name "#{i}-#{j}", with {braces}) } }
	end
	@encoder.encode(@array)
end

duel "binary decoder: Integer, Float and TimestampUtc" do
	once do
		@integer = PG::BinaryDecoder::Integer.new
		@float = PG::BinaryDecoder::Float.new
		@timestamp = PG::BinaryDecoder::TimestampUtc.new
		@int8s = TEXT_VALUES[:integers].map { |value| [value.to_i].pack("q>") }
		@float8s = TEXT_VALUES[:floats].map { |value| [value.to_f].pack("G") }
		@times = TIMES.map { |time| PG::BinaryEncoder::TimestampUtc.new.encode(time) }
	end
	@int8s.each { |value| @integer.decode(value) }
	@float8s.each { |value| @float.decode(value) }
	@times.each { |value| @timestamp.decode(value) }
end

duel "binary encoder: Int8, Float8 and TimestampUtc" do
	once do
		@int8 = PG::BinaryEncoder::Int8.new
		@float8 = PG::BinaryEncoder::Float8.new
		@timestamp = PG::BinaryEncoder::TimestampUtc.new
		@integers = TEXT_VALUES[:integers].map(&:to_i)
		@floats = TEXT_VALUES[:floats].map(&:to_f)
	end
	@integers.each { |value| @int8.encode(value) }
	@floats.each { |value| @float8.encode(value) }
	TIMES.each { |value| @timestamp.encode(value) }
end

#!/usr/bin/env ruby

module PG
	module TextEncoder
		class Date < SimpleEncoder
			STRFTIME_ISO_DATE = "%Y-%m-%d".freeze
			def encode(value)
				value.strftime(STRFTIME_ISO_DATE)
			end
		end

		class TimestampWithoutTimeZone < SimpleEncoder
			STRFTIME_ISO_DATETIME_WITHOUT_TIMEZONE = "%Y-%m-%d %H:%M:%S.%N".freeze
			def encode(value)
				value.strftime(STRFTIME_ISO_DATETIME_WITHOUT_TIMEZONE)
			end
		end

		class TimestampWithTimeZone < SimpleEncoder
			STRFTIME_ISO_DATETIME_WITH_TIMEZONE = "%Y-%m-%d %H:%M:%S.%N %:z".freeze
			def encode(value)
				value.strftime(STRFTIME_ISO_DATETIME_WITH_TIMEZONE)
			end
		end

		#
		# The following class definitions are for documentation purpose only.
		#
		# Corresponding classes and methods are defined in pg_text_encoder.c
		#

		# This is the encoder class for the PostgreSQL bool type.
		class Boolean < SimpleEncoder
		end

		# This is the encoder class for the PostgreSQL int types.
		#
		# Non-Number values are expected to have method +to_i+ defined.
		class Integer < SimpleEncoder
		end

		# This is the encoder class for the PostgreSQL float types.
		class Float < SimpleEncoder
		end

		# This is the encoder class for the PostgreSQL text types.
		#
		# Non-String values are expected to have method +to_str+ defined.
		class String < SimpleEncoder
		end

		# This is the encoder class for PostgreSQL array types.
		#
		# All values are encoded according to the #element_type
		# accessor. Sub-arrays are encoded recursively.
		class Array < CompositeEncoder
		end

		# This is the encoder class for PostgreSQL identifiers.
		#
		# An Array value can be used for "schema.table.column" type identifiers:
		#   PG::TextEncoder::Identifier.new.encode(['schema', 'table', 'column'])
		#       => "schema"."table"."column"
		#
		class Identifier < CompositeEncoder
		end

		# This is the encoder class for PostgreSQL literals.
		#
		# A literal is quoted and escaped by the +'+ character.
		class QuotedLiteral < CompositeEncoder
		end
	end
end # module PG


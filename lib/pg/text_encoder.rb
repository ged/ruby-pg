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
	end
end # module PG


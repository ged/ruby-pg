#!/usr/bin/env ruby

module PG

	module Type
		module TextEncoder
			class Date
				STRFTIME_ISO_DATE = "%Y-%m-%d".freeze
				def self.call(value)
					value.strftime(STRFTIME_ISO_DATE)
				end
			end

			class TimestampWithoutTimeZone
				STRFTIME_ISO_DATETIME_WITHOUT_TIMEZONE = "%Y-%m-%d %H:%M:%S.%N".freeze
				def self.call(value)
					value.strftime(STRFTIME_ISO_DATETIME_WITHOUT_TIMEZONE)
				end
			end

			class TimestampWithTimeZone
				STRFTIME_ISO_DATETIME_WITH_TIMEZONE = "%Y-%m-%d %H:%M:%S.%N %:z".freeze
				def self.call(value)
					value.strftime(STRFTIME_ISO_DATETIME_WITH_TIMEZONE)
				end
			end
		end
	end

end # module PG


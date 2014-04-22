#!/usr/bin/env ruby

module PG
	module TextEncoder
		class DATE
			STRFTIME_ISO_DATE = "%Y-%m-%d".freeze
			def self.call(value)
				value.strftime(STRFTIME_ISO_DATE)
			end
		end

		class TIMESTAMP_WITHOUT_TIME_ZONE
			STRFTIME_ISO_DATETIME_WITHOUT_TIMEZONE = "%Y-%m-%d %H:%M:%S.%N".freeze
			def self.call(value)
				value.strftime(STRFTIME_ISO_DATETIME_WITHOUT_TIMEZONE)
			end
		end

		class TIMESTAMP_WITH_TIME_ZONE
			STRFTIME_ISO_DATETIME_WITH_TIMEZONE = "%Y-%m-%d %H:%M:%S.%N %:z".freeze
			def self.call(value)
				value.strftime(STRFTIME_ISO_DATETIME_WITH_TIMEZONE)
			end
		end
	end
end # module PG


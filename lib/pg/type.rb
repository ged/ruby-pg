#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


module PG

	module Type
		module Text
			class TimeBase
				ISO_DATE = /\A(\d{4})-(\d\d)-(\d\d)\z/
				ISO_DATETIME_WITHOUT_TIMEZONE = /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(\.\d+)?\z/
				ISO_DATETIME_WITH_TIMEZONE = /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(\.\d+)?([-\+]\d\d)\z/
				STRFTIME_ISO_DATE = "%Y-%m-%d".freeze
				STRFTIME_ISO_DATETIME_WITHOUT_TIMEZONE = "%Y-%m-%d %H:%M:%S.%N".freeze
				STRFTIME_ISO_DATETIME_WITH_TIMEZONE = "%Y-%m-%d %H:%M:%S.%N %:z".freeze

				def self.format
					0
				end
			end

			class DATE < TimeBase
				def self.encode(value)
					value.strftime(STRFTIME_ISO_DATE)
				end

				def self.decode(string, tuple, field)
					if string =~ ISO_DATE
						Time.new $1.to_i, $2.to_i, $3.to_i
					else
						raise ArgumentError, sprintf("unexpected time format for tuple %d field %d: %s", tuple, field, string)
					end
				end

				def self.oid
					1082
				end
			end

			class TIMESTAMP_WITHOUT_TIME_ZONE < TimeBase
				def self.encode(value)
					value.strftime(STRFTIME_ISO_DATETIME_WITHOUT_TIMEZONE)
				end

				def self.decode(string, tuple, field)
					if string =~ ISO_DATETIME_WITHOUT_TIMEZONE
						Time.new $1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, "#{$6}#{$7}".to_r
					else
						raise ArgumentError, sprintf("unexpected time format for tuple %d field %d: %s", tuple, field, string)
					end
				end

				def self.oid
					1114
				end
			end

			class TIMESTAMP_WITH_TIME_ZONE < TimeBase
				def self.encode(value)
					value.strftime(STRFTIME_ISO_DATETIME_WITH_TIMEZONE)
				end

				def self.decode(string, tuple, field)
					if string =~ ISO_DATETIME_WITH_TIMEZONE
						Time.new $1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, "#{$6}#{$7}".to_r, "#{$8}:00"
					else
						raise ArgumentError, sprintf("unexpected time format for tuple %d field %d: %s", tuple, field, string)
					end
				end

				def self.oid
					1184
				end
			end
		end
	end

end # module PG


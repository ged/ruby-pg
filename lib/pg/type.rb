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

			INT2ARRAY = ARRAY.build("INT2ARRAY", INT2, false, 1005)
			INT4ARRAY = ARRAY.build("INT4ARRAY", INT4, false, 1007)
			TEXTARRAY = ARRAY.build("TEXTARRAY", TEXT, true, 1009)
			VARCHARARRAY = ARRAY.build("VARCHARARRAY", VARCHAR, true, 1015)
			INT8ARRAY = ARRAY.build("INT8ARRAY", INT8, false, 1016)
			FLOAT4ARRAY = ARRAY.build("FLOAT4ARRAY", FLOAT4, false, 1021)
			FLOAT8ARRAY = ARRAY.build("FLOAT8ARRAY", FLOAT8, false, 1022)

			TIMESTAMPARRAY = ARRAY.build("TIMESTAMP_WITHOUT_TIME_ZONE_ARRAY", TIMESTAMP_WITHOUT_TIME_ZONE, false, 1115)
			TIMESTAMPTZARRAY = ARRAY.build("TIMESTAMP_WITH_TIME_ZONE_ARRAY", TIMESTAMP_WITH_TIME_ZONE, false, 1185)
		end
	end

end # module PG


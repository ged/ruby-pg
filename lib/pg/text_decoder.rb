#!/usr/bin/env ruby

module PG
	module TextDecoder
		class Date
			ISO_DATE = /\A(\d{4})-(\d\d)-(\d\d)\z/

			def self.call(string, tuple, field)
				if string =~ ISO_DATE
					Time.new $1.to_i, $2.to_i, $3.to_i
				else
					raise ArgumentError, sprintf("unexpected time format for tuple %d field %d: %s", tuple, field, string)
				end
			end
		end

		class TimestampWithoutTimeZone
			ISO_DATETIME_WITHOUT_TIMEZONE = /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(\.\d+)?\z/

			def self.call(string, tuple, field)
				if string =~ ISO_DATETIME_WITHOUT_TIMEZONE
					Time.new $1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, "#{$6}#{$7}".to_r
				else
					raise ArgumentError, sprintf("unexpected time format for tuple %d field %d: %s", tuple, field, string)
				end
			end
		end

		class TimestampWithTimeZone
			ISO_DATETIME_WITH_TIMEZONE = /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(\.\d+)?([-\+]\d\d)\z/

			def self.call(string, tuple, field)
				if string =~ ISO_DATETIME_WITH_TIMEZONE
					Time.new $1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, "#{$6}#{$7}".to_r, "#{$8}:00"
				else
					raise ArgumentError, sprintf("unexpected time format for tuple %d field %d: %s", tuple, field, string)
				end
			end
		end
	end
end # module PG


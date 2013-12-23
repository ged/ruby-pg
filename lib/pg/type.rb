#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


module PG

	module Type
		module Text
			class TimeBase
				def self.encode(value)
					value.to_s
				end

				def self.decode(string, tuple, field)
					Time.new(string)
				end
			end
			class DATE < TimeBase
				def self.oid
					1082
				end
			end
			class TIMESTAMP_WITHOUT_TIME_ZONE < TimeBase
				def self.oid
					1114
				end
			end
			class TIMESTAMP_WITH_TIME_ZONE < TimeBase
				def self.oid
					1184
				end
			end
		end

		class NotDefined
			def self.encode(value)
				raise "no encoder defined for type #{value.class}"
			end

			def self.decode(res, tuple, field)
				raise "no type decoder defined for tuple #{tuple} field #{field}"
			end
		end
	end

end # module PG


#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


module PG

	class Type
		class TextTime
			def self.encode(value)
				value.to_s
			end

			def self.decode(res, tuple, field, string)
				Time.new(string)
			end
		end

		class NotDefined
			def self.encode(value)
				raise "no encoder defined for type #{value.class}"
			end

			def self.decode(res, _tuple, field, _string)
				raise "no type decoder defined for OID #{res.ftype(field)}"
			end
		end
	end

end # module PG


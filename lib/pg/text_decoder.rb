#!/usr/bin/env ruby

require 'date'
require 'json'

module PG
	module TextDecoder
		class Date < SimpleDecoder
			ISO_DATE = /\A(\d{4})-(\d\d)-(\d\d)\z/

			def decode(string, tuple=nil, field=nil)
				if string =~ ISO_DATE
					::Date.new $1.to_i, $2.to_i, $3.to_i
				else
					string
				end
			end
		end

		class JSON < SimpleDecoder
			def decode(string, tuple=nil, field=nil)
				::JSON.parse(string, quirks_mode: true)
			end
		end
	end
end # module PG


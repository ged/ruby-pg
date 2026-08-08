# -*- ruby -*-
# frozen_string_literal: true

module PG
	module TextEncoder
		# This is a encoder class for conversion of Ruby Date values to PostgreSQL date type.
		class Date < SimpleEncoder
			def encode(value)
				if value.respond_to?(:gregorian?)
					# Only create a new gregorian Date object if necessary
					value = value.gregorian unless value.gregorian?
					value.strftime("%Y-%m-%d")
				else
					value
				end
			end
		end
	end
end # module PG

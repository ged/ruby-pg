# -*- ruby -*-
# frozen_string_literal: true

require 'pg' unless defined?( PG )


module PG

	class Error < StandardError
		def initialize(msg, connection: nil, result: nil)
			@connection = connection
			@result = result
			super(msg)
		end
	end

end # module PG


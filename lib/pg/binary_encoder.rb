# -*- ruby -*-
# frozen_string_literal: true

module PG
	module BinaryEncoder
		# Convenience classes for timezone options
		class TimestampUtc < Timestamp
			def initialize(params={})
				super(params.merge(flags: PG::Coder::TIMESTAMP_DB_UTC))
			end
		end
		class TimestampLocal < Timestamp
			def initialize(params={})
				super(params.merge(flags: PG::Coder::TIMESTAMP_DB_LOCAL))
			end
		end
	end
end # module PG

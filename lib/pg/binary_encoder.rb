# -*- ruby -*-
# frozen_string_literal: true

module PG
	module BinaryEncoder
		# Convenience classes for timezone options
		class TimestampUtc < Timestamp
			def initialize(**kwargs)
				super(flags: PG::Coder::TIMESTAMP_DB_UTC, **kwargs)
			end
		end
		class TimestampLocal < Timestamp
			def initialize(**kwargs)
				super(flags: PG::Coder::TIMESTAMP_DB_LOCAL, **kwargs)
			end
		end
	end
end # module PG

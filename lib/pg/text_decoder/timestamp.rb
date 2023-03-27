# -*- ruby -*-
# frozen_string_literal: true

module PG
	module TextDecoder
		# Convenience classes for timezone options
		class TimestampUtc < Timestamp
			def initialize(**kwargs)
				super(flags: PG::Coder::TIMESTAMP_DB_UTC | PG::Coder::TIMESTAMP_APP_UTC, **kwargs)
			end
		end
		class TimestampUtcToLocal < Timestamp
			def initialize(**kwargs)
				super(flags: PG::Coder::TIMESTAMP_DB_UTC | PG::Coder::TIMESTAMP_APP_LOCAL, **kwargs)
			end
		end
		class TimestampLocal < Timestamp
			def initialize(**kwargs)
				super(flags: PG::Coder::TIMESTAMP_DB_LOCAL | PG::Coder::TIMESTAMP_APP_LOCAL, **kwargs)
			end
		end

		# For backward compatibility:
		TimestampWithoutTimeZone = TimestampLocal
		TimestampWithTimeZone = Timestamp
	end
end # module PG

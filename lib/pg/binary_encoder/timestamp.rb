# -*- ruby -*-
# frozen_string_literal: true

module PG
	module BinaryEncoder
		# Convenience classes for timezone options
		class TimestampUtc < Timestamp
			def initialize(hash={}, **kwargs)
				warn "PG::Coder.new(hash) is deprecated. Please use keyword arguments instead! Called from #{caller.first}" unless hash.empty?
				super(flags: PG::Coder::TIMESTAMP_DB_UTC, **hash, **kwargs)
			end
		end
		class TimestampLocal < Timestamp
			def initialize(hash={}, **kwargs)
				warn "PG::Coder.new(hash) is deprecated. Please use keyword arguments instead! Called from #{caller.first}" unless hash.empty?
				super(flags: PG::Coder::TIMESTAMP_DB_LOCAL, **hash, **kwargs)
			end
		end
	end
end # module PG

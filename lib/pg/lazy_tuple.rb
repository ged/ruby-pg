# -*- ruby -*-
# frozen_string_literal: true

require 'pg' unless defined?( PG )


class PG::LazyTuple

	### Return a String representation of the object suitable for debugging.
	def inspect
		"#<#{self.class} #{to_a.map(&:inspect).join(", ")}>"
	end

end

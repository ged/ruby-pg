#!/usr/bin/env ruby

module PG

	class Coder
		def _dump(level)
			name
		end

		def self._load(qname)
			_, nsp, name = *qname.split('::')
			PG.const_get(nsp).const_get(name)
		end
	end

end # module PG


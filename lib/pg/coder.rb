#!/usr/bin/env ruby

module PG

	class Coder
		NAMESPACES = [
			{ encoder: PG::TextEncoder,
		    decoder: PG::TextDecoder },
			{ encoder: PG::BinaryEncoder,
		    decoder: PG::BinaryDecoder },
		]

		def _dump(level)
			Marshal.dump([name, format, direction])
		end

		def self._load(obj)
			name, format, direction = *Marshal.load(obj)
			NAMESPACES[format][direction].const_get(name)
		end
	end

end # module PG


#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::ColumnMapping
	def oids
		types.map{|c| c.oid if c }
	end

	def inspect
		type_strings = types.map{|c| c ? "#{c.name}:#{c.format}" : 'nil' }
		"#<#{self.class} #{type_strings.join(' ')}>"
	end
end

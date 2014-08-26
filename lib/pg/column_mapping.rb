#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::ColumnMapping
	def oids
		coders.map{|c| c.oid if c }
	end

	def inspect
		type_strings = coders.map{|c| c ? "#{c.name}:#{c.format}" : 'nil' }
		"#<#{self.class} #{type_strings.join(' ')}>"
	end
end

#!/usr/bin/env ruby

require 'pg' unless defined?( PG )

# A TypeMapByColumn combines multiple types together, suitable to convert the
# input or result values of a given query. TypeMapByColumns are in particular
# useful in conjunction with prepared statements, since they can be cached
# alongside with the statement handle.
#
# This type map strategy is also used internally by TypeMapByOid, when the
# number of rows of a result set exceeds a given limit.
class PG::TypeMapByColumn
	def oids
		coders.map{|c| c.oid if c }
	end

	def inspect
		type_strings = coders.map{|c| c ? "#{c.name}:#{c.format}" : 'nil' }
		"#<#{self.class} #{type_strings.join(' ')}>"
	end
end

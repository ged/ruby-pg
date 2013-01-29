#!/usr/bin/env ruby

require 'pg' unless defined?( PG )


class PG::Result
    def values
	enum_for(:each_row).to_a
    end
end # class PG::Result

# Backward-compatible alias
PGresult = PG::Result

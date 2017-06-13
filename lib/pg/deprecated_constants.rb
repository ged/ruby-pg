# -*- ruby -*-
#encoding: utf-8

# Warn about use of deprecated constants when this is autoloaded
unless ENV['PG_SKIP_DEPRECATION_WARNING']
	callsite = caller(3).first

	warn <<-END_OF_WARNING
The PGconn, PGresult, and PGError constants are deprecated, and will be
removed as of version 1.0.

You should use PG::Connection, PG::Result, and PG::Error instead, respectively.

You can disable this warning by setting the PG_SKIP_DEPRECATION_WARNING environment
variable.

Called from #{callsite}
	END_OF_WARNING
end

PGconn   = PG::Connection
PGresult = PG::Result
PGError  = PG::Error


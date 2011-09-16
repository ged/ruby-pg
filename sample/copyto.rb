#!/usr/bin/env ruby

require 'pg'
require 'stringio'

# An example of how to stream data to your local host from the database as CSV.

$stderr.puts "Opening database connection ..."
conn = PGconn.connect( :dbname => 'test' )

### You can test the error case from the database side easily by
### changing one of the numbers at the end of one of the above rows to
### something non-numeric like "-".

$stderr.puts "Running COPY command ..."
buf = ''
conn.transaction do
	conn.exec( "COPY logs TO STDOUT WITH csv" )
	$stdout.puts( buf ) while buf = conn.get_copy_data
end

conn.finish


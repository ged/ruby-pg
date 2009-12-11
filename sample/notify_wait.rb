#!/usr/bin/env ruby
#
# Test script, demonstrating a non-poll notification for a table event.
#
# To use, create a table called 'test', and attach a NOTIFY trigger to it
# like so:
#
#     CREATE OR REPLACE FUNCTION notify_test()
#     RETURNS TRIGGER
#     LANGUAGE plpgsql
#     AS $$
#         BEGIN
#             NOTIFY woo;
#             RETURN NULL;
#         END
#     $$
#
#     CREATE TRIGGER notify_trigger
#     AFTER UPDATE OR INSERT OR DELETE
#     ON test
#     FOR EACH STATEMENT
#     EXECUTE PROCEDURE notify_test()
#

BEGIN {
        require 'pathname'
        basedir = Pathname.new( __FILE__ ).expand_path.dirname.parent
        libdir = basedir + 'lib'
        $LOAD_PATH.unshift( libdir.to_s ) unless $LOAD_PATH.include?( libdir.to_s )
}

require 'pg'

conn = PGconn.connect( :dbname => 'test' )
conn.exec( 'LISTEN woo' )  # register interest in the 'woo' event

puts "Waiting up to 30 seconds for for an event!"
conn.wait_for_notify( 30 ) do |notify, pid|
	puts "I got one from pid %d: %s" % [ pid, notify ]
end

puts "Awww, I didn't see any events."


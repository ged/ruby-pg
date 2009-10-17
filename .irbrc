#!/usr/bin/ruby -*- ruby -*-

BEGIN {
	require 'pathname'
	basedir = Pathname.new( __FILE__ ).dirname.expand_path
	extdir = basedir + "ext"

	puts ">>> Adding #{extdir} to load path..."
	$LOAD_PATH.unshift( extdir.to_s )
}


# Try to require the 'pg' library
begin
	$stderr.puts "Loading pg..."
	require 'pg'
rescue => e
	$stderr.puts "Ack! pg library failed to load: #{e.message}\n\t" +
		e.backtrace.join( "\n\t" )
end


#!/usr/bin/env ruby

require 'pathname'

module Postgres

	VERSION = '0.8.0'

	gemdir = Pathname( __FILE__ ).dirname.parent
	readme = gemdir + 'README.txt'

	header, message = readme.read.split( /^== Description/m )
	abort( message.strip )

end

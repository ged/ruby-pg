# pg

* https://bitbucket.org/ged/ruby-pg

## Description

Pg is the Ruby interface to the [PostgreSQL RDBMS][postgresql].

It works with PostgreSQL 8.2 and later.


## Requirements

* Ruby 1.8.7-p174 or later.
* PostgreSQL 8.2.x or later installed.

It may work with earlier versions as well, but those are not regularly tested.


## How To Install

Install via RubyGems:

	gem install pg

You may need to specify the path to the 'pg_config' program installed with
Postgres:

	gem install pg -- --with-pg-config=<path to pg_config>

For example, on a Mac with PostgreSQL installed via MacPorts (`port install
postgresql90`):

	gem install pg -- \
	  --with-pg-config=/opt/local/lib/postgresql90/bin/pg_config

See README.OS_X.md for more information about installing under MacOS X, and
README.windows.md for Windows build/installation instructions.


## Contributing

To report bugs, suggest features, or check out the source with Mercurial,
[check out the project page][bitbucket]. If you prefer Git, there's also a
[Github mirror][github].

After checking out the source, run:

	$ rake newb

This task will install any missing dependencies, run the tests/specs, and
generate the API documentation.


## Copying

This library is copyrighted by the authors.

Authors:

* Yukihiro Matsumoto <matz@ruby-lang.org> - Author of Ruby.
* Eiji Matsumoto <usagi@ruby.club.or.jp> - One of users who loves Ruby.
* Jeff Davis <ruby-pg@j-davis.com>

Thanks to:

* Noboru Saitou <noborus@netlab.jp> - Past maintainer.
* Dave Lee - Past maintainer.
* Guy Decoux (ts) <decoux@moulon.inra.fr> 
  
Maintainers:

* Michael Granger <ged@FaerieMUD.org>

You may redistribute this software under the terms of the Ruby license,
included in the file "LICENSE". The Ruby license also allows distribution
under the terms of the GPL, included in the file "GPL".

Portions of the code are from the PostgreSQL project, and are distributed
under the terms of the BSD license, included in the file "BSD".

Portions copyright LAIKA, Inc.


## Acknowledgments

We are thankful to the people at the ruby-list and ruby-dev mailing lists.
And to the people who developed PostgreSQL.


[postgresql]:http://www.postgresql.org/
[bitbucket]:http://bitbucket.org/ged/ruby-pg
[github]:https://github.com/ged/ruby-pg


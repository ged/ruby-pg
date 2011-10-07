## 0.11.0 [2011-02-09] Michael Granger <ged@FaerieMUD.org>

Enhancements:

* Added a PGresult#values method to fetch all result rows as an Array of 
  Arrays. Thanks to Jason Yanowitz (JYanowitz at enovafinancial dot com) for
  the patch.


## 0.10.1 [2011-01-19] Michael Granger <ged@FaerieMUD.org>

Bugfixes:

* Add an include guard for pg.h
* Simplify the common case require of the ext
* Include the extconf header
* Fix compatibility with versions of PostgreSQL without PQgetCancel. (fixes #36)
* Fix require for natively-compiled extension under Windows. (fixes #55)
* Change rb_yield_splat() to rb_yield_values() for compatibility with Rubinius. (fixes #54)


## 0.10.0 [2010-12-01] Michael Granger <ged@FaerieMUD.org>

Enhancements:

* Added support for the payload of NOTIFY events (w/Mahlon E. Smith)
* Updated the build system with Rubygems suggestions from RubyConf 2010

Bugfixes:

* Fixed issue with PGconn#wait_for_notify that caused it to miss notifications that happened after
  the LISTEN but before the wait_for_notify.

## 0.9.0 [2010-02-28] Michael Granger <ged@FaerieMUD.org>

Bugfixes.

## 0.8.0 [2009-03-28] Jeff Davis <davis.jeffrey@gmail.com>

Bugfixes, better Windows support.


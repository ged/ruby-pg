# frozen_string_literal: true
# -*- encoding: utf-8 -*-

require_relative 'lib/pg/version'

Gem::Specification.new do |spec|
  spec.name          = "pg"
  spec.version       = PG::VERSION
  spec.authors       = ["Michael Granger", "Lars Kanis"]
  spec.email         = ["ged@FaerieMUD.org", "lars@greiz-reinsdorf.de"]

  spec.summary       = "Pg is the Ruby interface to the {PostgreSQL RDBMS}[http://www.postgresql.org/]"
  spec.description   = "Pg is the Ruby interface to the {PostgreSQL RDBMS}[http://www.postgresql.org/].\n\nIt works with {PostgreSQL 9.2 and later}[http://www.postgresql.org/support/versioning/].\n\nA small example usage:\n\n  #!/usr/bin/env ruby\n\n  require 'pg'\n\n  # Output a table of current connections to the DB\n  conn = PG.connect( dbname: 'sales' )\n  conn.exec( \"SELECT * FROM pg_stat_activity\" ) do |result|\n    puts \"     PID | User             | Query\"\n    result.each do |row|\n      puts \" %7d | %-16s | %s \" %\n        row.values_at('pid', 'usename', 'query')\n    end\n  end"
  spec.homepage      = "https://github.com/ged/ruby-pg"
  spec.license       = "BSD-2-Clause"
  spec.required_ruby_version = ">= 2.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ged/ruby-pg"
  spec.metadata["changelog_uri"] = "https://github.com/ged/ruby-pg/blob/master/History.rdoc"
  spec.metadata["documentation_uri"] = "http://deveiate.org/code/pg"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features)/}) }
  end
  spec.extensions    = ["ext/extconf.rb"]
  spec.require_paths = ["lib"]
  spec.cert_chain    = ["certs/ged.pem"]
  spec.rdoc_options  = ["--main", "README.rdoc"]
end

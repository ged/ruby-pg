# -*- encoding: utf-8 -*-
# stub: pg 0.19.0.pre20160131124256 ruby lib
# stub: ext/extconf.rb

Gem::Specification.new do |s|
  s.name = "pg"
  s.version = "0.19.0.pre20160131124256"

  s.required_rubygems_version = Gem::Requirement.new("> 1.3.1") if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib"]
  s.authors = ["Michael Granger", "Lars Kanis"]
  s.cert_chain = ["certs/ged.pem"]
  s.date = "2016-01-31"
  s.description = "Pg is the Ruby interface to the {PostgreSQL RDBMS}[http://www.postgresql.org/].\n\nIt works with {PostgreSQL 8.4 and later}[http://www.postgresql.org/support/versioning/].\n\nA small example usage:\n\n  #!/usr/bin/env ruby\n\n  require 'pg'\n\n  # Output a table of current connections to the DB\n  conn = PG.connect( dbname: 'sales' )\n  conn.exec( \"SELECT * FROM pg_stat_activity\" ) do |result|\n    puts \"     PID | User             | Query\"\n    result.each do |row|\n      puts \" %7d | %-16s | %s \" %\n        row.values_at('procpid', 'usename', 'current_query')\n    end\n  end"
  s.email = ["ged@FaerieMUD.org", "lars@greiz-reinsdorf.de"]
  s.extensions = ["ext/extconf.rb"]
  s.extra_rdoc_files = ["Contributors.rdoc", "History.rdoc", "Manifest.txt", "README-OS_X.rdoc", "README-Windows.rdoc", "README.ja.rdoc", "README.rdoc", "ext/errorcodes.txt", "Contributors.rdoc", "History.rdoc", "README-OS_X.rdoc", "README-Windows.rdoc", "README.ja.rdoc", "README.rdoc", "POSTGRES", "LICENSE", "ext/gvl_wrappers.c", "ext/pg.c", "ext/pg_binary_decoder.c", "ext/pg_binary_encoder.c", "ext/pg_coder.c", "ext/pg_connection.c", "ext/pg_copy_coder.c", "ext/pg_errors.c", "ext/pg_result.c", "ext/pg_text_decoder.c", "ext/pg_text_encoder.c", "ext/pg_type_map.c", "ext/pg_type_map_all_strings.c", "ext/pg_type_map_by_class.c", "ext/pg_type_map_by_column.c", "ext/pg_type_map_by_mri_type.c", "ext/pg_type_map_by_oid.c", "ext/pg_type_map_in_ruby.c", "ext/util.c"]
  s.files = ["BSDL", "ChangeLog", "Contributors.rdoc", "History.rdoc", "LICENSE", "Manifest.txt", "POSTGRES", "README-OS_X.rdoc", "README-Windows.rdoc", "README.ja.rdoc", "README.rdoc", "Rakefile", "Rakefile.cross", "ext/errorcodes.def", "ext/errorcodes.rb", "ext/errorcodes.txt", "ext/extconf.rb", "ext/gvl_wrappers.c", "ext/gvl_wrappers.h", "ext/pg.c", "ext/pg.h", "ext/pg_binary_decoder.c", "ext/pg_binary_encoder.c", "ext/pg_coder.c", "ext/pg_connection.c", "ext/pg_copy_coder.c", "ext/pg_errors.c", "ext/pg_result.c", "ext/pg_text_decoder.c", "ext/pg_text_encoder.c", "ext/pg_type_map.c", "ext/pg_type_map_all_strings.c", "ext/pg_type_map_by_class.c", "ext/pg_type_map_by_column.c", "ext/pg_type_map_by_mri_type.c", "ext/pg_type_map_by_oid.c", "ext/pg_type_map_in_ruby.c", "ext/util.c", "ext/util.h", "ext/vc/pg.sln", "ext/vc/pg_18/pg.vcproj", "ext/vc/pg_19/pg_19.vcproj", "lib/pg.rb", "lib/pg/basic_type_mapping.rb", "lib/pg/coder.rb", "lib/pg/connection.rb", "lib/pg/constants.rb", "lib/pg/exceptions.rb", "lib/pg/result.rb", "lib/pg/text_decoder.rb", "lib/pg/text_encoder.rb", "lib/pg/type_map_by_column.rb", "sample/array_insert.rb", "sample/async_api.rb", "sample/async_copyto.rb", "sample/async_mixed.rb", "sample/check_conn.rb", "sample/copyfrom.rb", "sample/copyto.rb", "sample/cursor.rb", "sample/disk_usage_report.rb", "sample/issue-119.rb", "sample/losample.rb", "sample/minimal-testcase.rb", "sample/notify_wait.rb", "sample/pg_statistics.rb", "sample/replication_monitor.rb", "sample/test_binary_values.rb", "sample/wal_shipper.rb", "sample/warehouse_partitions.rb", "spec/data/expected_trace.out", "spec/data/random_binary_data", "spec/helpers.rb", "spec/pg/basic_type_mapping_spec.rb", "spec/pg/connection_spec.rb", "spec/pg/result_spec.rb", "spec/pg/type_map_by_class_spec.rb", "spec/pg/type_map_by_column_spec.rb", "spec/pg/type_map_by_mri_type_spec.rb", "spec/pg/type_map_by_oid_spec.rb", "spec/pg/type_map_in_ruby_spec.rb", "spec/pg/type_map_spec.rb", "spec/pg/type_spec.rb", "spec/pg_spec.rb"]
  s.homepage = "https://bitbucket.org/ged/ruby-pg"
  s.licenses = ["BSD", "Ruby", "GPL"]
  s.rdoc_options = ["--main", "README.rdoc"]
  s.required_ruby_version = Gem::Requirement.new(">= 1.9.3")
  s.rubygems_version = "2.4.8"
  s.summary = "Pg is the Ruby interface to the {PostgreSQL RDBMS}[http://www.postgresql.org/]"

  if s.respond_to? :specification_version then
    s.specification_version = 4

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_development_dependency(%q<hoe-mercurial>, ["~> 1.4"])
      s.add_development_dependency(%q<hoe-deveiate>, ["~> 0.7"])
      s.add_development_dependency(%q<hoe-highline>, ["~> 0.2"])
      s.add_development_dependency(%q<rdoc>, ["~> 4.0"])
      s.add_development_dependency(%q<rake-compiler>, ["~> 0.9"])
      s.add_development_dependency(%q<rake-compiler-dock>, ["~> 0.5"])
      s.add_development_dependency(%q<hoe>, ["~> 3.12"])
      s.add_development_dependency(%q<hoe-bundler>, ["~> 1.0"])
      s.add_development_dependency(%q<rspec>, ["~> 3.0"])
    else
      s.add_dependency(%q<hoe-mercurial>, ["~> 1.4"])
      s.add_dependency(%q<hoe-deveiate>, ["~> 0.7"])
      s.add_dependency(%q<hoe-highline>, ["~> 0.2"])
      s.add_dependency(%q<rdoc>, ["~> 4.0"])
      s.add_dependency(%q<rake-compiler>, ["~> 0.9"])
      s.add_dependency(%q<rake-compiler-dock>, ["~> 0.5"])
      s.add_dependency(%q<hoe>, ["~> 3.12"])
      s.add_dependency(%q<hoe-bundler>, ["~> 1.0"])
      s.add_dependency(%q<rspec>, ["~> 3.0"])
    end
  else
    s.add_dependency(%q<hoe-mercurial>, ["~> 1.4"])
    s.add_dependency(%q<hoe-deveiate>, ["~> 0.7"])
    s.add_dependency(%q<hoe-highline>, ["~> 0.2"])
    s.add_dependency(%q<rdoc>, ["~> 4.0"])
    s.add_dependency(%q<rake-compiler>, ["~> 0.9"])
    s.add_dependency(%q<rake-compiler-dock>, ["~> 0.5"])
    s.add_dependency(%q<hoe>, ["~> 3.12"])
    s.add_dependency(%q<hoe-bundler>, ["~> 1.0"])
    s.add_dependency(%q<rspec>, ["~> 3.0"])
  end
end

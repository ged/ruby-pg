# -*- ruby -*-

# No pg gem, since "bundle package" fails on bundler-2.7+, if the extension isn't built
# gemspec

source "https://rubygems.org/"

group :development do
  gem "rdoc", "~> 6.4"
  gem "mini_portile2", "~> 2.1"
end

# Duel, for the performance regression guards in duel/: install it with
# `bundle config set --local with duel`, and run them with `rake duel`.
# Its PostgreSQL plugin needs a released pg, which would load its own
# pg_ext in the specs and in Duel's workers, so the group is optional,
# and the released pg is the source gem, whose lib/ has no pg_ext of the
# Ruby's version (lib/3.4/pg_ext) for pg.rb to load ahead of this tree's.
group :duel, optional: true do
  # Duel requires Ruby 3.4 or later
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.4")
    gem "duel", "~> 0.1.8"
    gem "duel-postgresql", "~> 0.1.5"
    gem "pg", force_ruby_platform: true
  end
  gem "stackprof", platforms: :mri
end

group :test do
  gem "bundler", ">= 1.16", "< 5.0"
  gem "rake-compiler", "~> 1.0"
  gem "rake-compiler-dock", "~> 1.11.0" #, git: "https://github.com/rake-compiler/rake-compiler-dock"
  gem "rspec", "~> 3.5"
  # "bigdecimal" is a gem on ruby-3.4+ and it's optional for ruby-pg.
  # Specs should succeed without it, but 4 examples are then excluded.
  # With bigdecimal commented out here, corresponding tests are omitted on ruby-3.4+ but are executed on ruby < 3.4.
  # That way we can check both situations in CI.
  # gem "bigdecimal", "~> 3.0"
  gem "drb"
end

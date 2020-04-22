# -*- rspec -*-
#encoding: utf-8

require_relative '../helpers'

require 'timeout'
require 'socket'
require 'pg'

describe PG::LogicalReplication do

  it "can replicate", :without_transaction do
    @conn.internal_encoding = 'UTF-8'
    dbname = @conn.conninfo_hash[:dbname]
    host = @conn.conninfo_hash[:host]
    port = @conn.conninfo_hash[:port]
    log_and_run @logfile, 'pg_recvlogical',
      '-h', host,
      '-p', port,
      '-d', dbname,
      '--slot', 'test_slot',
      '--create-slot',
      '-P', 'test_decoding'


    results = []
    t = Thread.new do
      PG::LogicalReplication.new(@conn.conninfo_hash.merge(slot: 'test_slot', replication_options: 'include-timestamp=on').select { |_, v| !v.nil? }) do |res|
        results << res
        Thread.exit if results.size >= 5
      end
    end

    # Wait for replication to start
    sleep 2

    @conn.exec(<<-SQL)
      CREATE TABLE teas ( kind TEXT );
      INSERT INTO teas VALUES ( '煎茶' )
          , ( '蕎麦茶' )
          , ( '魔茶' );
    SQL

    t.join

    expect(results[0]).to match(/^BEGIN\s\d+$/)
    [ '煎茶', '蕎麦茶', '魔茶' ].each_with_index do |tea, i|
      expect(results[i + 1]).to eq("table public.teas: INSERT: kind[text]:'#{tea}'")
    end
    # COMMIT 4446 (at 2020-04-22 10:51:39.603592-04)
    expect(results[4]).to match(/^COMMIT\s\d+\s\(at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d+)?[-+]\d{2}\)$/)
  end

end

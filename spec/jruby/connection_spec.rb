#!/usr/bin/env rspec
#encoding: utf-8

BEGIN {
	require 'pathname'

	basedir = Pathname( __FILE__ ).dirname.parent.parent
	libdir = basedir + 'lib'

	$LOAD_PATH.unshift( basedir.to_s ) unless $LOAD_PATH.include?( basedir.to_s )
	$LOAD_PATH.unshift( libdir.to_s ) unless $LOAD_PATH.include?( libdir.to_s )
}

require 'spec/lib/helpers'
require 'rspec'
require 'pg'

describe PG::Connection do
  before(:all) do
    @conn = setup_testing_db( "PG_Connection" )
  end

  before( :each ) do
    @conn.exec( 'BEGIN' ) unless example.metadata[:without_transaction]
  end

  after( :each ) do
    @conn.exec( 'ROLLBACK' ) unless example.metadata[:without_transaction]
  end

  after(:all) do
    teardown_testing_db( @conn )
  end

  describe 'basic connection properties' do
    it 'can sends the options to the server' do
      conn = PG.connect "#{@conninfo} options = '-c geqo=off'"
      res = conn.query('show geqo')
      res.getvalue(0, 0).should== 'off'
    end

    it 'correctly translates the server version' do
      @conn.server_version.should >=(80200)
    end

    it 'quotes identifier correctly' do
      table_name = @conn.quote_ident('foo')
      column_name = @conn.quote_ident('bar')
      @conn.exec "CREATE TABLE #{table_name} (#{column_name} text)"
    end

    it 'quotes identifier correctly when the static quote_ident is called' do
      table_name = PG::Connection.quote_ident('foo')
      column_name = PG::Connection.quote_ident('bar')
      @conn.exec "CREATE TABLE #{table_name} (#{column_name} text)"
    end

    it 'assumes standard conforming strings is off before any connection is created' do
      # make sure that there are no last connections cached
      foo = "\x00"
      PG::Connection.escape_bytea(foo).should== "\\000"
      @conn.exec 'SET standard_conforming_strings = on'
      PG::Connection.escape_bytea(foo).should== "\\000"
      @conn.exec 'SET standard_conforming_strings = off'
      PG::Connection.escape_bytea(foo).should== "\\\\000"
    end

    it 'handles NULL columns properly' do
      res = @conn.exec 'VALUES (NULL)'
      res.getvalue( 0, 0 ).should be_nil
    end

    it 'returns an empty array when fields is called after an CREATE/DROP query' do
      res = @conn.exec 'CREATE TABLE FOO (BAR INT)'
      res.fields.should == []
      res = @conn.exec 'DROP TABLE FOO'
      res.fields.should == []
    end

    it 'returns an empty result set when an INSERT is executed' do
      res = @conn.exec 'CREATE TABLE foo (bar INT)'
      res.should_not be_nil
      res = @conn.exec 'INSERT INTO foo VALUES (1234)'
      res.should_not be_nil
      res.nfields.should ==(0)
    end

    it 'delete does not fail' do
      @conn.exec 'CREATE TABLE foo (bar INT)'
      @conn.exec 'INSERT INTO foo VALUES (1234)'
      res = @conn.exec 'DELETE FROM foo WHERE bar = 1234'
      res.should_not be_nil
      res.nfields.should ==(0)
    end

    it 'returns id when a new row is inserted' do
      @conn.exec 'CREATE TABLE foo (id SERIAL UNIQUE, bar INT)'
      @conn.prepare 'query', 'INSERT INTO foo(bar) VALUES ($1) returning id'
      @conn.send_query_prepared 'query', ['1234']
      @conn.block
      res = @conn.get_last_result
      res.should_not be_nil
      res.nfields.should ==(1)
    end
  end

  describe 'encoding' do
    it 'handles ascii strings properly' do
      str = 'foo'
      res = @conn.exec 'VALUES ($1::text)', [str]
      res.getvalue(0, 0).should == str
    end

    it 'can set encoding to US-ASCII' do
      old_internal_encoding = @conn.internal_encoding
      begin
        @conn.internal_encoding = 'US-ASCII'
      ensure
        @conn.internal_encoding = old_internal_encoding
      end
    end

    it 'handles any utf-8 strings properly' do
      str = 'いただきます！'
      res = @conn.exec 'VALUES ($1::text)', [str]
      res.getvalue(0, 0).should == str
    end
  end

  describe 'prepared statements' do
    it 'execute successfully' do
      @conn.prepare '', 'SELECT 1 AS n'
      res = @conn.exec_prepared ''
      res[0]['n'].should== '1'
    end

    it 'execute successfully with parameters' do
      @conn.prepare '', 'SELECT $1::text AS n'
      res = @conn.exec_prepared '', ['foo']
      res[0]['n'].should== 'foo'
    end

    it 'should return an error if a prepared statement is used more than once' do
      expect {
        @conn.prepare 'foo', 'SELECT $1::text AS n'
        @conn.prepare 'foo', 'SELECT $1::text AS n'
      }.to raise_error(PGError, /already exists/i)
    end

    it 'return an error if a parameter is not bound to a type' do
      expect {
        @conn.prepare 'bar', 'SELECT $1 AS n'
      }.to raise_error(PGError, /could not determine/i)
    end

    it 'return an error if a prepared statement does not exist' do
      expect {
        @conn.exec_prepared 'foobar'
      }.to raise_error(PGError, /does not exist/i)
    end

    it 'can execute prepared queries that have no results' do
      @conn.prepare 'create_query', 'CREATE TABLE FOO (BAR TEXT)'
      res = @conn.exec_prepared 'create_query'
      @conn.prepare 'insert_query', 'INSERT INTO FOO VALUES ($1)'
      res = @conn.exec_prepared 'insert_query', ['baz']
    end
  end

  describe 'error handling' do
    it 'should maintain a correct state after an error' do
      @conn.exec 'ROLLBACK'

      expect {
        res = @conn.exec 'select * from foo'
      }.to raise_error(PGError, /does not exist/)

      expect {
        res = @conn.exec 'SELECT 1 / 0 AS n'
      }.to raise_error(PGError, /by zero/)
    end
  end

  describe 'query cancelling' do
    it 'should correctly accept queries after a query is cancelled' do
      @conn.exec 'ROLLBACK'
      @conn.send_query 'SELECT pg_sleep(1000)'
      @conn.cancel
      res = @conn.get_result
      @conn.exec 'select pg_sleep(1)'
    end

    it 'exec should clear results from previous queries' do
      @conn.exec 'ROLLBACK'
      @conn.send_query 'SELECT pg_sleep(1000)'
      @conn.cancel
      @conn.block
      @conn.exec 'ROLLBACK'
    end

    it "described_class#block should allow a timeout" do
      @conn.send_query( "select pg_sleep(3)" )

      start = Time.now
      @conn.block( 0.1 )
      finish = Time.now

      (finish - start).should be_within( 0.05 ).of( 0.1 )
    end
  end

  describe 'authentication' do
    it 'can authenticate clients using the clear password' do
      @conn.exec 'ROLLBACK'
      begin
        @conn.exec "CREATE USER password WITH PASSWORD 'secret'"
      rescue
        # ignore
      end
      conn = PG.connect "#{@conninfo} user=password password=secret"
      conn.finish
    end

    it 'fails if no password was given and a password is required' do
      expect {
        @conn.exec 'ROLLBACK'
        begin
          @conn.exec "CREATE USER password WITH PASSWORD 'secret'"
        rescue
          # ignore
        end
        conn = PG.connect "#{@conninfo} user=password"
      }.to raise_error(PG::ConnectionBad, /no password supplied/)
    end

    it 'connects to the server using ssl' do
      @conn.exec 'ROLLBACK'
      begin
        @conn.exec "CREATE USER ssl WITH PASSWORD 'secret'"
      rescue
        # ignore
      end
      conn = PG.connect "#{@conninfo} user=ssl password=secret sslmode=require"
      conn.finish
    end

    it 'can authenticate clients using the md5 hash' do
      @conn.exec 'ROLLBACK'
      begin
        @conn.exec "CREATE USER encrypt WITH PASSWORD 'md5'"
      rescue
        # ignore
      end
      conn = PG.connect "#{@conninfo} user=encrypt password=md5"
      conn.finish
    end

    it 'fails if the user does not exist' do
      expect {
        conn = PG.connect "#{@conninfo} user=nonexistentuser"
      }.to raise_error(PGError, /does not exist/)
    end
  end

  describe 'reset' do
    it 'should reconnect when reset is called' do
      conn = PG.connect @conninfo
      old_pid = conn.exec('select pg_backend_pid()').getvalue(0, 0)
      conn.reset
      new_pid = conn.exec('select pg_backend_pid()').getvalue(0, 0)
      old_pid.should_not== new_pid
    end
  end

  describe 'large object api' do
    it "handles large object methods properly" do
      fd = oid = 0
      @conn.transaction do
        oid = @conn.lo_create( 0 )
        fd = @conn.lo_open( oid, PG::INV_READ|PG::INV_WRITE )
        count = @conn.lo_write( fd, "foobar" )
        @conn.lo_read( fd, 10 ).should be_nil()
        @conn.lo_tell(fd).should ==(6)
        @conn.lo_lseek( fd, 0, PG::SEEK_SET )
        @conn.lo_tell(fd).should ==(0)
        @conn.lo_read( fd, 10 ).should == 'foobar'
      end

    end
    it "closes large objects properly" do
      @conn.transaction do
        oid = @conn.lo_create( 0 )
        fd = @conn.lo_open( oid, PG::INV_READ|PG::INV_WRITE )
        @conn.lo_close(fd)
        expect {
          @conn.lo_write(fd, 'foo')
        }.to raise_error(PGError)
      end
    end

    it "unlinks large objects properly" do
      @conn.transaction do
        oid = @conn.lo_create( 0 )
        fd = @conn.lo_open( oid, PG::INV_READ|PG::INV_WRITE )
        @conn.lo_unlink(oid)
        expect {
          @conn.lo_open(oid)
        }.to raise_error(PGError)
      end
    end

    it "truncates large objects properly" do
      @conn.transaction do
        oid = @conn.lo_create( 0 )
        fd = @conn.lo_open( oid, PG::INV_READ|PG::INV_WRITE )
        @conn.lo_write(fd, 'foobar')
        @conn.lo_seek(fd, 0, PG::SEEK_SET )
        @conn.lo_read(fd, 10).should ==('foobar')
        @conn.lo_truncate(fd, 3)
        @conn.lo_seek(fd, 0, PG::SEEK_SET )
        @conn.lo_read(fd, 10).should ==('foo')
      end
    end
  end

  describe 'COPY operations' do
    it 'can copy data in and out correctly' do
      @conn.exec %{ CREATE TABLE ALTERNATE_PARKING_NYC (
                    Subject text,
                    "Start Date" date,
                    "Start Time" time,
                    "End Date" date,
                    "End Time" time,
                    "All day event" boolean,
                    "Reminder on/off" boolean,
                    "Reminder Date" date,
                    "Reminder Time" time)
                  }
      res = @conn.exec %{ Copy ALTERNATE_PARKING_NYC FROM STDIN WITH CSV HEADER QUOTE AS '"'}
      res.result_status.should == PG::PGRES_COPY_IN
      File.readlines('spec/jruby/data/sample.csv').each do |line|
        @conn.put_copy_data(line)
      end
      @conn.put_copy_end
      @conn.get_last_result
      res = @conn.exec 'select * from ALTERNATE_PARKING_NYC'
      res.ntuples.should == 40
    end
  end
end

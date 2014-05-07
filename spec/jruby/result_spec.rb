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

describe PG::Result do
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

  it "should return an error if a duplicate key is inserted" do
		@conn.exec 'CREATE TABLE Foo ( bar INTEGER PRIMARY KEY )'
    query = 'INSERT INTO Foo (bar) VALUES (1)'
    @conn.exec query
		expect {
      @conn.exec query
		}.to raise_error( PGError, /duplicate/i )
  end

  it 'returns the number of rows affected by INSERT and DELETE' do
    @conn.exec 'CREATE TABLE FOO (BAR INT)'
    res = @conn.exec 'INSERT INTO FOO VALUES (1)'
    res.cmd_tuples.should == 1
    @conn.exec 'INSERT INTO FOO VALUES (1)'
    res = @conn.exec 'DELETE FROM FOO'
    res.cmd_tuples.should == 2
  end

  it 'nfields return the correct number of columns' do
    res = @conn.exec 'SELECT 1 as n'
    res.nfields.should== 1
  end

  it 'ftype should return the type oid of the column' do
    res = @conn.exec "SELECT 123::money as n"
    res = @conn.exec "select format_type(#{res.ftype(0)}, #{res.fmod(0)})"
    res.getvalue(0, 0).should== "money"
  end

  it 'ftype should return the type oid of the column' do
    res = @conn.exec "SELECT 'foo'::bytea as n"
    res = @conn.exec "select format_type(#{res.ftype(0)}, #{res.fmod(0)})"
    res.getvalue(0, 0).should== "bytea"
  end

  it 'returns the names of the fields in the result set' do
    res = @conn.exec "Select 1 as n"
    res.fields.should== ['n']
  end

  it 'returns the names of the fields in the result set' do
    res = @conn.exec "Select 1 as n"
    res.fname(0).should== 'n'
  end

  it 'returns newlines in text fields properly' do
    value = "foo\nbar"
    res = @conn.exec "VALUES ('#{@conn.escape value}')"
    res.getvalue(0, 0).should== value
  end

  it 'escapes multibyte strings properly' do
    value = 'いただきます！'
    res = @conn.exec "VALUES ('#{@conn.escape value}')"
    res.getvalue(0, 0).should== value
  end
end

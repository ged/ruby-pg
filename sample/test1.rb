#! /usr/bin/env ruby
#
# original file src/test/examples/testlibpq.c
# 
require 'pg'

def main
  pghost = nil
  pgport = nil
  pgoptions = nil
  pgtty = nil
  dbname = "template1"
  begin
    conn = PGconn.connect(pghost,pgport,pgoptions,pgtty,dbname)
    if $DEBUG
      fd = open("/tmp/trace.out","w")
      conn.trace(fd)
    end 
    res = conn.exec("BEGIN")
    res.clear
    res = conn.exec("DECLARE myportal CURSOR FOR select * from pg_database")
    res.clear

    res = conn.exec("FETCH ALL in myportal")
    if (res.result_status != PGresult::PGRES_TUPLES_OK)
      raise PGerror,"FETCH ALL command didn't return tuples properly\n"
    end

    for fld in res.fields
      printf("%-15s",fld)
    end
    printf("\n\n")

    res.values.each do |tupl|
      tupl.each do |fld|
	printf("%-15s",fld)
      end
      printf("\n")
    end
    res = conn.exec("CLOSE myportal")
    res = conn.exec("END")
    res.clear
    conn.close

    if $DEBUG
      fl.close
    end
  rescue PGError
    if (conn.status == PGconn::CONNECTION_BAD)
      printf(STDERR, "We have lost the connection to the backend, so ")
      printf(STDERR, "further processing is impossible.  ")
      printf(STDERR, "Terminating.\n")
    else
      printf(STDERR, conn.error)
    end
    exit(1)
  end
end

main
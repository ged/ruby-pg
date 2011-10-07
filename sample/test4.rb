#! /usr/bin/env ruby
#
# original file src/test/examples/testlibpq4.c
#     this test programs shows to use LIBPQ to make multiple backend
#
require 'pg'

def main
  if (ARGV.size != 4)
    printf(STDERR,"usage: %s tableName dbName1 dbName2\n", ARGV[0])
    printf(STDERR,"    compares two tables in two databases\n")
    exit(1)
  end
  tblname = ARGV[1]
  dbname1 = ARGV[2]
  dbname2 = ARGV[3]
  pghost = nil
  pgport = nil
  pgoptions = nil
  pgtty = nil

  begin
    conn1 = PGconn.connect(pghost,pgport,pgoptions,pgtty,dbname1)
    conn2 = PGconn.connect(pghost,pgport,pgoptions,pgtty,dbname2)
  rescue PGError
    printf(STDERR,"connection to database.\n")
    exit(1)
  end
  begin
    res1 = conn1.exec("BEGIN")
    res1.clear
    res1 = conn1.exec("DECLARE myportal CURSOR FOR select * from pg_database")
    res1.clear

    res1 = conn1.exec("FETCH ALL in myportal")
    if (res1.status != PGresult::TUPLES_OK)
      raise PGerror,"FETCH ALL command didn't return tuples properly\n"
    end

    for fld in res1.fields
      printf("%-15s",fld)
    end
    printf("\n\n")

    res1.result.each do |tupl|
      tupl.each do |fld|
	printf("%-15s",fld)
      end
      printf("\n")
    end
    res1 = conn1.exec("CLOSE myportal")
    res1 = conn1.exec("END")
    res1.clear
    conn1.close

  rescue PGError
    if (conn1.status == PGconn::CONNECTION_BAD)
      printf(STDERR, "We have lost the connection to the backend, so ")
      printf(STDERR, "further processing is impossible.  ")
      printf(STDERR, "Terminating.\n")
    else
      printf(STDERR, conn1.error)
    end
    exit(1)
  end
end

main




#! /usr/bin/env ruby
#
# original file src/test/examples/testlibpq2.c
#                       Test of the asynchronous notification interface
# CREATE TABLE TBL1 (i int4);
# CREATE TABLE TBL2 (i int4);
# CREATE RULE r1 AS ON INSERT TO TBL1 DO (INSERT INTO TBL2 values (new.i); \
#                                         NOTIFY TBL2);
# Then start up this program
# After the program has begun, do
# INSERT INTO TBL1 values (10);


require 'pg'

def main
  pghost = nil
  pgport = nil
  pgoptions = nil
  pgtty = nil
  dbname = ENV['USER'] 
  begin
    conn = PGconn.connect(pghost,pgport,pgoptions,pgtty,dbname)
  rescue PGError
    printf(STDERR, "Connection to database '%s' failed.\n",dbname)
    exit(2)
  end
  begin
    res = conn.exec("LISTEN TBL2")
  rescue PGError
    printf(STDERR, "LISTEN command failed\n")
    exit(2)
  end
  res.clear
  while 1
    notify = conn.get_notify
    if (notify)
      printf(STDERR,"ASYNC NOTIFY '%s' from backend pid '%d' received\n",notify[0],notify[1])
      break
    end
  end
end

main

require "postgres"

def main
  conn = PGconn.connect("localhost",5432,"","")
  puts("dbname: " + conn.db + "\thost: " + conn.host + "\tuser: " + conn.user)

  # Transaction
  conn.exec("BEGIN")
  lobj = conn.loimport("losample.rb")
  lobjnum = lobj.oid
  puts("loimport ok! oid=" + lobj.oid.to_s)
  lobj.open
  lobj.seek(0,PGlarge::SEEK_SET) # SEEK_SET or SEEK_CUR or SEEK_END
  buff =  lobj.read(18)
  puts buff
  if 'require "postgres"' == buff
    puts "read ok!"
  end
  lobj.seek(0,PGlarge::SEEK_END)
  buff = lobj.write("write test ok?\n")
  puts lobj.tell
  puts 'export test .file:lowrite.losample add "write test of?"...'
  lobj.export("lowrite.txt")
  lobj.close
  conn.exec("COMMIT")
  begin
    lobj.read(1)
    puts "boo!"
    return
  rescue
    puts "ok! Large Object is closed"
  end
  conn.exec("BEGIN")
  puts lobjnum.to_s
  lobj = conn.loopen(lobjnum)
  puts "large object reopen ok!"
  lobj.seek(0,PGlarge::SEEK_SET) # SEEK_SET or SEEK_CUR or SEEK_END
  buff =  lobj.read(18)
  puts buff
  puts "reread ok!"
  conn.exec("COMMIT")
  lobj.unlink
  puts "large object unlink"
end

main


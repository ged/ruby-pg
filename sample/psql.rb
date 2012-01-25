#!/usr/bin/env ruby
#
# an interactive front-end to postgreSQL
#
# Original source code is written by C.
#  Copyright (c) 1996, Regents of the University of California
#
# ruby version is written by ematsu
#  Copyright (c) 1997  Eiji-usagi-MATSUmoto <ematsu@pfu.co.jp>
#
# Changes:
#
#  Fri 12 Dec 19:56:34 JST 1997
#  * replace puts -> print
#
# $Id$
#

require "pg"
require "parsearg"
require "psqlHelp"

PROMPT           = "=> "
MAX_QUERY_BUFFER = 20000
DEFAULT_SHELL    = "/bin/sh"
DEFAULT_EDITOR   = "vi"
DEFAULT_FIELD_SEP= "|"

PsqlSettings = Struct.new("PsqlSettings", :db, :queryFout, :opt, :prompt,
			  :gfname, :notty,:pipe, :echoQuery,:quiet,
			  :singleStep, :singleLineMode, :useReadline)
			  
PrintOpt = Struct.new("PrintOpt", :header, :align, :standard, :html3,
		      :expanded, :pager, :fieldSep, :tableOpt,
		      :caption, :fieldName)

$readline_ok = TRUE

def usage()
  printf("Usage: psql.rb [options] [dbname]\n")
  printf("\t -a authsvc              set authentication service\n")
  printf("\t -A                      turn off alignment when printing out attributes\n")
  printf("\t -c query                run single query (slash commands too)\n")
  printf("\t -d dbName               specify database name\n")
  printf("\t -e                      echo the query sent to the backend\n")
  printf("\t -f filename             use file as a source of queries\n")
  printf("\t -F sep                  set the field separator (default is \" \")\n")
  printf("\t -h host                 set database server host\n")
  printf("\t -H                      turn on html3.0 table output\n")
  printf("\t -l                      list available databases\n")
  printf("\t -n                      don't use readline library\n")
  printf("\t -o filename             send output to filename or (|pipe)\n")
  printf("\t -p port                 set port number\n")
  printf("\t -q                      run quietly (no messages, no prompts)\n")
  printf("\t -s                      single step mode (prompts for each query)\n")
  printf("\t -S                      single line mode (i.e. query terminated by newline)\n")
  printf("\t -t                      turn off printing of headings and row count\n")
  printf("\t -T html                 set html3.0 table command options (cf. -H)\n")
  printf("\t -x                      turn on expanded output (field names on left)\n")
  exit(1)
end
$USAGE = 'usage'

def slashUsage(ps)
  printf(" \\?           -- help\n")
  printf(" \\a           -- toggle field-alignment (currenty %s)\n", on(ps.opt.align))
  printf(" \\C [<captn>] -- set html3 caption (currently '%s')\n", ps.opt.caption );
  printf(" \\connect <dbname>  -- connect to new database (currently '%s')\n", ps.db.db)
  printf(" \\copy {<table> to <file> | <file> from <table>}\n")
  printf(" \\d [<table>] -- list tables in database or columns in <table>, * for all\n")
  printf(" \\da          -- list aggregates\n")
  printf(" \\di          -- list only indices\n")
  printf(" \\ds          -- list only sequences\n")
  printf(" \\dS          -- list system tables and indexes\n")
  printf(" \\dt          -- list only tables\n")
  printf(" \\dT          -- list types\n")
  printf(" \\e [<fname>] -- edit the current query buffer or <fname>\n")
  printf(" \\E [<fname>] -- edit the current query buffer or <fname>, and execute\n")
  printf(" \\f [<sep>]   -- change field separater (currently '%s')\n", ps.opt.fieldSep)
  printf(" \\g [<fname>] [|<cmd>] -- send query to backend [and results in <fname> or pipe]\n")
  printf(" \\h [<cmd>]   -- help on syntax of sql commands, * for all commands\n")
  printf(" \\H           -- toggle html3 output (currently %s)\n", on(ps.opt.html3))
  printf(" \\i <fname>   -- read and execute queries from filename\n")
  printf(" \\l           -- list all databases\n")
  printf(" \\m           -- toggle monitor-like table display (currently %s)\n", on(ps.opt.standard))
  printf(" \\o [<fname>] [|<cmd>] -- send all query results to stdout, <fname>, or pipe\n")
  printf(" \\p           -- print the current query buffer\n")
  printf(" \\q           -- quit\n")
  printf(" \\r           -- reset(clear) the query buffer\n")
  printf(" \\s [<fname>] -- print history or save it in <fname>\n")
  printf(" \\t           -- toggle table headings and row count (currently %s)\n", on(ps.opt.header))
  printf(" \\T [<html>]  -- set html3.0 <table ...> options (currently '%s')\n", ps.opt.tableOpt)
  printf(" \\x           -- toggle expanded output (currently %s)\n", on(ps.opt.expanded))
  printf(" \\! [<cmd>]   -- shell escape or command\n")
end

def on(f)
  if f
    return "on"
  else
    return "off"
  end
end

def toggle(settings, sw, msg)
  sw = !sw
  if !settings.quiet
    printf(STDERR, "turned %s %s\n", on(sw), msg)
  end
  return sw
end

def gets(prompt, source)
  if source == STDIN
    if ($readline_ok)
      line = Readline.readline(prompt,source)
    else
      STDOUT.print(prompt)
      STDOUT.flush()
      line = source.gets
    end
  end

  if line == nil
      return nil
  else
    if line.length > MAX_QUERY_BUFFER
      printf(STDERR, "line read exceeds maximum length.  Truncating at %d\n",
	     MAX_QUERY_BUFFER)
      return line[0..MAX_QUERY_BUFFER-1]
    else
      return line
    end
  end
end

def PSQLexec(ps, query)
  res = ps.db.exec(query)

  if res == nil
    printf(STDERR, "%s\n", ps.db.error())

  else
    if (res.status() == PG::COMMAND_OK ||
	res.status() == PG::TUPLES_OK)
      return res
    end

    if !ps.quiet
      printf(STDERR, "%s\n", ps.db.error())
    end

    res.clear()
  end

end

def listAllDbs(ps)
  query = "select * from pg_database;"

  if (results = PSQLexec(ps, query)) == nil
    return 1

  else
    results.print(ps.queryFout, ps.opt)
    results.clear()
    return 0
  end
end

def tableList(ps, deep_tablelist, info_type, system_tables)
  listbuf  = "SELECT usename, relname, relkind, relhasrules"
  listbuf += "  FROM pg_class, pg_user "
  listbuf += "WHERE usesysid = relowner "
  case info_type
  when 't'
    listbuf += "and ( relkind = 'r') "
  when 'i'
    listbuf += "and ( relkind = 'i') "
    haveIndexes = true
  when 'S'
    listbuf += "and ( relkind = 'S') "
  else
    listbuf += "and ( relkind = 'r' OR relkind = 'i' OR relkind='S') "
    haveIndexes = true
  end
  if (!system_tables)
    listbuf += "and relname !~ '^pg_' "
  else
    listbuf += "and relname ~ '^pg_' "  
  end
  if (haveIndexes)
    listbuf += "and (relkind != 'i' OR relname !~'^xinx')"
  end
  listbuf += "  ORDER BY relname "

  res = PSQLexec(ps, listbuf)
  if res == nil
    return
  end

  # first, print out the attribute names
  nColumns = res.num_tuples
  if nColumns > 0
    if deep_tablelist
      table = res.result
      res.clear
      for i in 0..nColumns-1
	tableDesc(ps, table[i][1])
      end
    else
      # Display the information

      printf("\nDatabase    = %s\n", ps.db.db)
      printf(" +------------------+----------------------------------+----------+\n")
      printf(" |  Owner           |             Relation             |   Type   |\n")
      printf(" +------------------+----------------------------------+----------+\n")

      # next, print out the instances
      for i in 0..res.num_tuples-1
	printf(" | %-16.16s", res.getvalue(i, 0))
	printf(" | %-32.32s | ", res.getvalue(i, 1))
	rk = res.getvalue(i, 2)
	rr = res.getvalue(i, 3)
	if (rk.eql?("r"))
	  printf("%-8.8s |", if (rr[0] == 't') then "view?" else "table" end)
	else
	  printf("%-8.8s |", "index")
	end
	printf("\n")
      end
      printf(" +------------------+----------------------------------+----------+\n")
      res.clear()
    end
  else
    printf(STDERR, "Couldn't find any tables!\n")
  end
end

def tableDesc(ps, table)
  descbuf  = "SELECT a.attnum, a.attname, t.typname, a.attlen"
  descbuf += "  FROM pg_class c, pg_attribute a, pg_type t "
  descbuf += "    WHERE c.relname = '"
  descbuf += table
  descbuf += "'"
  descbuf += "    and a.attnum > 0 "
  descbuf += "    and a.attrelid = c.oid "
  descbuf += "    and a.atttypid = t.oid "
  descbuf += "  ORDER BY attnum "

  res = PSQLexec(ps, descbuf)
  if res == nil
    return
  end

  # first, print out the attribute names
  nColumns = res.num_tuples()
  if nColumns > 0
    #
    # Display the information
    #

    printf("\nTable    = %s\n", table)
    printf("+----------------------------------+----------------------------------+-------+\n")
    printf("|              Field               |              Type                | Length|\n")
    printf("+----------------------------------+----------------------------------+-------+\n")

    # next, print out the instances
    for i in 0..res.num_tuples-1

      printf("| %-32.32s | ", res.getvalue(i, 1))
      rtype = res.getvalue(i, 2);
      rsize = res.getvalue(i, 3).to_i

      if (rtype.eql?("text"))
	printf("%-32.32s |", rtype)
	printf("%6s |", "var")
      elsif (rtype.eql?("bpchar"))
	printf("%-32.32s |", "(bp)char")
	printf("%6i |", if (rsize > 0) then rsize - 4 else 0 end)
      elsif  (rtype.eql?("varchar"))
	printf("%-32.32s |", rtype)
	printf("%6d |", if (rsize > 0) then rsize - 4 else 0 end)
      else
	# array types start with an underscore
	if (rtype[0, 1] != '_')
	  printf("%-32.32s |", rtype)
	else
	  newname = rtype + "[]"
	  printf("%-32.32s |", newname)
	end
	if (rsize > 0)
	  printf("%6d |", rsize)
	else
	  printf("%6s |", "var")
	end
      end
      printf("\n")
    end
    printf("+----------------------------------+----------------------------------+-------+\n")

    res.clear()

  else
    printf(STDERR, "Couldn't find table %s!\n", table)
  end
end

def unescape(source)
  dest = source.gsub(/(\\n|\\r|\\t|\\f|\\\\)/) {
    |c|
    case c
    when "\\n"
      "\n"
    when "\\r"
      "\r"
    when "\\t"
      "\t"
    when "\\f"
      "\f"
    when "\\\\"
      "\\"
    end
  }
  return dest
end

def do_shell(command)
  if !command
    command = ENV["SHELL"]
    if shellName == nil
      command = DEFAULT_SHELL
    end
  end
  system(command);
end

def do_help(topic)
  if !topic
    printf("type \\h <cmd> where <cmd> is one of the following:\n")

    left_center_right = 'L' # Start with left column
    for i in 0..QL_HELP.length-1
      case left_center_right
      when  'L'
	printf("    %-25s", QL_HELP[i][0])
	left_center_right = 'C'

      when 'C'
	printf("%-25s", QL_HELP[i][0])
	left_center_right = 'R'

      when 'R'
	printf("%-25s\n", QL_HELP[i][0])
	left_center_right = 'L'

      end
    end
    if (left_center_right != 'L')
      STDOUT.print("\n")
    end
    printf("type \\h * for a complete description of all commands\n")
  else
    help_found = FALSE
    for i in 0..QL_HELP.length-1
      if QL_HELP[i][0] == topic || topic == "*"
	help_found = TRUE
	printf("Command: %s\n", QL_HELP[i][0])
	printf("Description: %s\n", QL_HELP[i][1])
	printf("Syntax:\n")
	printf("%s\n", QL_HELP[i][2])
	printf("\n")
      end
    end
    if !help_found
      printf("command not found, ")
      printf("try \\h with no arguments to see available help\n")
    end
  end
end

def do_edit(filename_arg, query)
  if filename_arg
    fname = filename_arg
    error = FALSE
  else
    fname = sprintf("/tmp/psql.rb.%d", $$)
    p fname
    if test(?e, fname)
      File.unlink(fname)
    end

    if query
      begin
	fd = File.new(fname, "w")
	if query[query.length-1, 1] != "\n"
	  query += "\n"
	end
	if fd.print(query) != query.length
	  fd.close
	  File.unlink(fname)
	  error = TRUE
	else
	  error = FALSE
	end
	fd.close
      rescue
	error = TRUE
      end
    else
      error = FALSE
    end
  end

  if error
    status = 1
  else
    editFile(fname)
    begin 
    fd = File.new(fname, "r")
      query = fd.read
      fd.close
      if query == nil
	status = 1
      else
	query.sub!(/[ \t\f\r\n]*$/, "")
	if query.length != 0
	  status = 3
	else
	  query  = nil
	  status = 1
	end
      end
    rescue
      status = 1
    ensure
      if !filename_arg
	if test(?e, fname)
	  File.unlink(fname)
	end
      end
    end
  end
  return status, query
end

def editFile(fname)
  editorName = ENV["EDITOR"]
  if editorName == nil
    editorName = DEFAULT_EDITOR
  end
  system(editorName + " " + fname)
end

def do_connect(settings, new_dbname)
  dbname = settings.db.db

  if !new_dbname
    printf(STDERR, "\\connect must be followed by a database name\n");
  else
    olddb = settings.db

    begin 
      printf("closing connection to database: %s\n", dbname);
      settings.db = PG.connect(olddb.host, olddb.port, "", "", new_dbname)
      printf("connecting to new database: %s\n", new_dbname)
      olddb.finish()
    rescue
      printf(STDERR, "%s\n", $!)
      printf("reconnecting to %s\n", dbname)
      settings.db = PG.connect(olddb.host, olddb.port,"", "", dbname)
    ensure
      settings.prompt = settings.db.db + PROMPT
    end
  end
end

def do_copy(settings, table, from_p, file)
  if (table == nil || from_p == nil || file == nil)
    printf("Syntax error, reffer \\copy help with  \\? \n")
    return
  end

  if from_p.upcase! == "FROM"
    from = TRUE
  else
    from = FALSE
  end

  query  = "COPY "
  query += table

  if from
    query += " FROM stdin"
    copystream = File.new(file, "r")
  else
    query += " TO stdout"
    copystream = File.new(file, "w")
  end

  begin
    success = SendQuery(settings, query, from, !from, copystream);
    copystream.close
    if !settings.quiet
      if success
	printf("Successfully copied.\n");
      else
	printf("Copy failed.\n");
      end
    end
  rescue
    printf(STDERR, "Unable to open file %s which to copy.",
	   if from then "from" else "to" end)
  end
end

def handleCopyOut(settings, copystream)
  copydone = FALSE

  while !copydone
    copybuf = settings.db.getline

    if !copybuf
      copydone = TRUE
    else
      if copybuf == "\\."
	copydone = TRUE
      else
	copystream.print(copybuf + "\n")
      end
    end
  end
  copystream.flush
  settings.db.endcopy
end

def handleCopyIn(settings, mustprompt, copystream)
  copydone = FALSE

  if mustprompt
    STDOUT.print("Enter info followed by a newline\n")
    STDOUT.print("End with a backslash and a ")
    STDOUT.print("period on a line by itself.\n")
  end

  while !copydone
    if mustprompt
      STDOUT.print(">> ")
      STDOUT.flush
    end

    copybuf = copystream.gets
    if copybuf == nil
      settings.db.putline("\\.\n")
      copydone = TRUE
      break
    end
    settings.db.putline(copybuf)
    if copybuf == "\\.\n"
      copydone = TRUE
    end
  end
  settings.db.endcopy
end

def setFout(ps, fname)
  if (ps.queryFout && ps.queryFout != STDOUT)
    ps.queryFout.close
  end

  if !fname
    ps.queryFout = STDOUT
  else
    begin 
      if fname[0, 1] == "|"
	dumy, ps.queryFout = pipe(fname)
	ps.pipe = TRUE
      else
	ps.queryFout = File.new(fname, "w+")
	ps.pipe = FALSE
      end
    rescue
      ps.queryFout = STDOUT
      ps.pipe = FALSE
    end
  end
end

def HandleSlashCmds(settings, line, query)
  status = 1
  cmd = unescape(line[1, line.length])
  args = cmd.split

  case args[0]
  when 'a' # toggles to align fields on output 
    settings.opt.align = 
      toggle(settings, settings.opt.align, "field alignment")

  when 'C' # define new caption
    if !args[1]
      settings.opt.caption = ""
    else
      settings.opt.caption = args[1]
    end

  when 'c', 'connect' # connect new database
    do_connect(settings, args[1])

  when 'copy' # copy from file
    do_copy(settings, args[1], args[2], args[3])

  when 'd' # \d describe tables or columns in a table
    if !args[1]
      tableList(settings, FALSE, 'b', FALSE)
    elsif args[1] == "*"
      tableList(settings, FALSE, 'b', FALSE)
      tableList(settings, TRUE, 'b', FALSE)
    else
      tableDesc(settings, args[1])
    end

  when 'da'
    descbuf =  "SELECT a.aggname AS aggname, t.typname AS type, "
    descbuf += "obj_description (a.oid) as description "
    descbuf += "FROM pg_aggregate a, pg_type t "
    descbuf += "WHERE a.aggbasetype = t.oid "
    if (args[1])
      descbuf += "AND a.aggname ~ '^"
      descbuf += args[1]
      descbuf += "' "
    end
    descbuf += "UNION SELECT a.aggname AS aggname, "
    descbuf += "'all types' as type, obj_description (a.oid) "
    descbuf += "as description FROM pg_aggregate a "
    descbuf += "WHERE a.aggbasetype = 0"
    if (args[1])
      descbuf += "AND a.aggname ~ '^"
      descbuf += args[1]
      descbuf += "' "
    end
    descbuf += "ORDER BY aggname, type;"
    res = SendQuery(settings, descbuf, FALSE, FALSE, 0)

  when 'di'
    tableList(settings, FALSE, 'i', FALSE)

  when 'ds'
    tableList(settings, FALSE, 'S', FALSE)

  when 'dS'
    tableList(settings, FALSE, 'b', TRUE)

  when 'dt'
    tableList(settings, FALSE, 't', FALSE)
    
  when 'e' # edit 
    status, query = do_edit(args[1], query)

  when 'E'
    if args[1]
      begin
	lastfile = args[1]
	File.file?(lastfile) && (mt = File.mtime(lastfile))
	editFile(lastfile)
	File.file?(lastfile) && (mt2 = File.mtime(lastfile))
	fd = File.new(lastfile, "r")
	if mt != mt2
	  MainLoop(settings, fd)
	  fd.close()
	else
	  if !settings.quiet
	    printf(STDERR, "warning: %s not modified. query not executed\n", lastfile)
	  end
	  fd.close()
	end
      rescue
	#
      end
    else
      printf(STDERR, "\\r must be followed by a file name initially\n");
    end
  when 'f'
    if args[1]
      settings.opt.fieldSep = args[1]
      if !settings.quiet
	printf(STDERR, "field separater changed to '%s'\n", settings.opt.fieldSep)
      end
    end

  when 'g' # \g means send query
    if !args[1]
      settings.gfname = nil
    else
      settings.gfname = args[1]
    end
    status = 0

  when 'h' # help
    if args[2]
      args[1] += " " + args[2]
    end
    do_help(args[1])

  when 'i' # \i is include file
    if args[1]
      begin
	fd = File.open(args[1], "r")
	MainLoop(settings, fd)
	fd.close()
      rescue Errno::ENOENT
	printf(STDERR, "file named %s could not be opened\n", args[1])
      end
    else
      printf(STDERR, "\\i must be followed by a file name\n")
    end
  when 'l' # \l is list database
    listAllDbs(settings)

  when 'H'
    settings.opt.html3 =
       toggle(settings, settings.opt.html3, "HTML3.0 tabular output")

    if settings.opt.html3 
      settings.opt.standard = FALSE
    end

  when 'o'
    setFout(settings, args[1])

  when 'p'
    if query
      File.print(query)
      File.print("\n")
    end

  when 'q' # \q is quit
    status = 2

  when 'r' # reset(clear) the buffer
    query = nil
    if !settings.quiet
      printf(STDERR, "buffer reset(cleared)\n")
    end

  when 's' # \s is save history to a file
    begin
      if (args[1])
	fd = File.open(args[1], "w")
      else
	fd = STDOUT
      end
      Readline::HISTORY.each do |his|
	fd.write (his + "\n")
      end
      if !fd.tty?
	begin
	  fd.close
	end
      end
    rescue
      printf(STDERR, "cannot write history \n");
    end

  when 'm' # monitor like type-setting
    settings.opt.standard =
      toggle(settings, settings.opt.standard, "standard SQL separaters and padding")
    if settings.opt.standard
      settings.opt.html3 = FALSE
      settings.opt.expanded = FALSE
      settings.opt.align = TRUE
      settings.opt.header = TRUE
      if settings.opt.fieldSep
	settings.opt.fieldSep = ""
      end
      settings.opt.fieldSep = "|"
      if !settings.quiet
	printf(STDERR, "field separater changed to '%s'\n", settings.opt.fieldSep)
      end
    else
      if settings.opt.fieldSep
	settings.opt.fieldSep = ""
      end
      settings.opt.fieldSep = DEFAULT_FIELD_SEP
      if !settings.quiet
	printf(STDERR, "field separater changed to '%s'\n", settings.opt.fieldSep)
      end
    end

  when 't' # toggle headers
    settings.opt.header = 
      toggle(settings, settings.opt.header, "output headings and row count")

  when 'T' # define html <table ...> option
    if !args[1]
      settings.opt.tableOpt = nil
    else
      settings.opt.tableOpt = args[1]
    end

  when 'x'
    settings.opt.expanded =
      toggle(settings, settings.opt.expanded, "expanded table representation")

  when '!'
    do_shell(args[1])

  when '?' # \? is help
    slashUsage(settings)
  end

  return status, query
end

def SendQuery(settings, query, copy_in, copy_out, copystream)
  if settings.singleStep
    printf("\n**************************************")
    printf("*****************************************\n")
  end

  if (settings.echoQuery || settings.singleStep)
    printf(STDERR, "QUERY: %s\n", query);
  end

  if settings.singleStep
    printf("\n**************************************");
    printf("*****************************************\n")
    STDOUT.flush
    printf("\npress return to continue ..\n");
    gets("", STDIN);
  end

  begin
    results = settings.db.exec(query)
    case results.status
    when PG::TUPLES_OK
      success = TRUE
      if settings.gfname
	setFout(settings, settings.gfname)
	settings.gfname = nil
	results.print(settings.queryFout, settings.opt)
	settings.queryFout.flush
	if settings.queryFout != STDOUT
	  settings.queryFout.close
	  settings.queryFout = STDOUT
	end
      else
	results.print(settings.queryFout, settings.opt)
	settings.queryFout.flush
      end
      results.clear

    when PG::EMPTY_QUERY
      success = TRUE

    when PG::COMMAND_OK
      success = TRUE
      if !settings.quiet
	printf("%s\n", results.cmdstatus)
      end

    when PG::COPY_OUT
      success = TRUE
      if copy_out
	  handleCopyOut(settings, copystream)
      else
	if !settings.quiet
	  printf("Copy command returns...\n")
	end

	handleCopyOut(settings, STDOUT)
      end

    when PG::COPY_IN
      success = TRUE
      if copy_in
	handleCopyIn(settings, FALSE, copystream)
      else
	handleCopyIn(settings, !settings.quiet, STDIN)
      end
    end

    if (settings.db.status == PG::CONNECTION_BAD)
      printf(STDERR, "We have lost the connection to the backend, so ")
      printf(STDERR, "further processing is impossible.  ")
      printf(STDERR, "Terminating.\n")
      exit(2)
    end

    # check for asynchronous returns
    # notify = settings.db.notifies()
    # if notify
    #   printf(STDERR,"ASYNC NOTIFY of '%s' from backend pid '%d' received\n",
    #   notify.relname, notify.be_pid)
    # end

  rescue
    printf(STDERR, "%s", $!)
    success = FALSE
  end

  return success
end

def MainLoop(settings, source)

  success        = TRUE
  interactive    = TRUE
  insideQuote    = FALSE
  querySent      = FALSE
  done           = FALSE

  query          = nil
  queryWaiting   = nil
  slashCmdStatus = -1
  interactive    = (source == STDIN && !settings.notty)

  if settings.quiet
    settings.prompt = nil
  else
    settings.prompt =  settings.db.db + PROMPT
  end

  while !done
    if slashCmdStatus == 3
      line = query
      query = nil
    else
      if interactive && !settings.quiet
	if insideQuote
	  settings.prompt[settings.prompt.length-3,1] = "\'"
	elsif (queryWaiting != nil && !querySent)
	  settings.prompt[settings.prompt.length-3,1] = "-"
	else
	  settings.prompt[settings.prompt.length-3,1] = "="
	end
      end
      line = gets(settings.prompt, source)
    end

    if line == nil
      printf("EOF\n")
      done = TRUE
    else

      ### debbegging information ###
      if !interactive && !settings.singleStep && !settings.quiet
	printf(STDERR, "%s\n", line)
      end

      ### ommit comment ###
      begin_comment = line.index("--")
      if begin_comment
	line = line[0, begin_comment]
      end

      ### erase unnecessary characters ###
      line.gsub!(/[ \t\f\n\r]+\z/, "")
      if line.length == 0
	next
      end
      ### begin slash command handling ###
      if line[0, 1] == "\\"
	query = line
	slashCmdStatus, query = HandleSlashCmds(settings, line, nil)
	if slashCmdStatus == 0 && query != nil
	  success = SendQuery(settings, query, FALSE, FALSE, 0) && success
	  querySent = TRUE
	elsif slashCmdStatus == 1
	  query = nil
	elsif slashCmdStatus == 2
	  break
	end
	line = nil
	next
      end

      ### begin query command handling ###
      slashCmdStatus = -1
      if settings.singleLineMode
	success = SendQuery(settings, line, FALSE, FALSE, 0) && success
	querySent = TRUE
      else

	if queryWaiting 
	  queryWaiting += " " + line 
        else
	  queryWaiting =  line
        end
      
        for i in 0..line.length-1
	  if line[i, 1] == "\'"
	    insideQuote = !insideQuote
	  end
        end

        if !insideQuote
	  if line[line.length-1, 1] == ";"
	    query = queryWaiting
	    queryWaiting = nil

	    success = SendQuery(settings, query, FALSE, FALSE, 0) && success
	    querySent = TRUE
	  else
	    querySent = FALSE
	  end
        else
	  querySent = FALSE
        end
      end
    end
  end # while
  return success
end

def main
  dbname = nil
  host = "localhost"
  port = 5432
  qfilename = nil

  singleQuery = nil
  settings = PsqlSettings.new(nil, nil, nil, nil, nil, FALSE, FALSE, 
			      FALSE, FALSE, FALSE, FALSE, FALSE)
  settings.opt = PrintOpt.new(FALSE, FALSE, FALSE, FALSE, FALSE,
			      FALSE, nil, nil, nil, nil)

  listDatabases = FALSE
  successResult = TRUE
  singleSlashCmd = FALSE

  settings.opt.align = TRUE
  settings.opt.header = TRUE
  settings.queryFout = STDOUT
  settings.opt.fieldSep = DEFAULT_FIELD_SEP.dup
  settings.opt.pager = TRUE
  settings.quiet = FALSE
  settings.notty = FALSE
  settings.useReadline = TRUE

  parsed = parseArgs(0, nil, "AelHnsqStx", "a:", "c:", "d:", "f:", "F:",
		     "h:", "o:", "p:", "T:")

  if $OPT_A
    settings.opt.align = FALSE
  end

  if $OPT_a
    #fe_setauthsvc(optarg, errbuf);
    printf("not implemented, sorry.\n")
    exit(1)
  end

  if $OPT_c
    singleQuery = $OPT_c
    if singleQuery[0, 1] == "\\"
      singleSlashCmd = TRUE
    end
  end

  if $OPT_d
    dbname = $OPT_d
  end

  if $OPT_e
    settings.echoQuery = TRUE
  end

  if $OPT_f
    qfilename = $OPT_f
  end

  if $OPT_F
    settings.opt.fieldSep = $OPT_F
  end

  if $OPT_l
    listDatabases = TRUE
  end

  if $OPT_h
    host = $OPT_h
  end

  if $OPT_H
    settings.opt.html3 = TRUE
  end

  if $OPT_n
    settings.useReadline = FALSE
  end

  if $OPT_o
    setFout(settings, $OPT_o)
  end

  if $OPT_p
    port = $OPT_p.to_i
  end

  if $OPT_q
    settings.quiet = TRUE
  end

  if $OPT_s
    settings.singleStep = TRUE
  end

  if $OPT_S
    settings.singleLineMode = TRUE
  end

  if $OPT_t
    settings.opt.header = FALSE
  end

  if $OPT_T
    settings.opt.tableOpt = $OPT_T
  end

  if $OPT_x
    settings.opt.expanded = TRUE
  end

  if ARGV.length == 1
    dbname = ARGV[0]
  end

  if listDatabases
    dbname = "template1"
  end

  settings.db = PG.connect(host, port, "", "", dbname);
  dbname = settings.db.db

  if settings.db.status() == PG::CONNECTION_BAD
    printf(STDERR, "Connection to database '%s' failed.\n", dbname)
    printf(STDERR, "%s", settings.db.error)
    exit(1)
  end
  if listDatabases
    exit(listAllDbs(settings))
  end
  if (!settings.quiet && !singleQuery && !qfilename)
    printf("Welcome to the POSTGRESQL interactive sql monitor:\n")
    printf("  Please read the file COPYRIGHT for copyright terms of POSTGRESQL\n\n")
    printf("   type \\? for help on slash commands\n")
    printf("   type \\q to quit\n")
    printf("   type \\g or terminate with semicolon to execute query\n")
    printf(" You are currently connected to the database: %s\n\n", dbname)
  end
  if (qfilename || singleSlashCmd)
    if singleSlashCmd
      line = singleQuery
    else
      line = sprintf("\\i %s", qfilename)
    end
    HandleSlashCmds(settings, line, "")
  else
    if settings.useReadline
      begin
	require "readline"
	$readline_ok = TRUE
      rescue
	$readline_ok = FALSE
      end
    else
      $readline_ok = FALSE
    end
    if singleQuery
      success = SendQuery(settings, singleQuery, false, false, 0)
      successResult = success
    else
      successResult = MainLoop(settings, STDIN)
    end
  end
  settings.db.finish()
  return !successResult
end

main


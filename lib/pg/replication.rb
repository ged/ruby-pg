# frozen_string_literal: true

class PG::LogicalReplication

  EPOCH = Time.new(2000, 1, 1, 0, 0, 0)

  attr_accessor :slot, :sysid, :xlogpos, :dbname, :tli, :connection,
    :last_received_lsn, :last_processed_lsn, :last_server_lsn, :last_status

  def initialize(*args, &block)
    @connection_params = PG::Connection.parse_connect_args(*args)

    if !(@connection_params =~ /replication='?database/)
      @connection_params << " replication='database'"
    end

    _, @dbname = *@connection_params.match(/dbname='([^\s]+)'/)

    sub, @slot = *@connection_params.match(/slot='([^\s]+)'/)
    @connection_params.gsub!(sub, ' ')

    sub, @xlogpos = *@connection_params.match(/xlogpos='([^\s]+)'/)
    @connection_params.gsub!(sub, ' ') if @xlogpos

    sub, @tli = *@connection_params.match(/tli='([^\s]+)'/)
    @connection_params.gsub!(sub, ' ') if @tli

    sub, @options = *@connection_params.match(/replication_options='([^']+)'/)
    if @options
      @connection_params.gsub!(sub, ' ')
      @options = @options.split(/\s+/).inject({}) do |acc, x|
        k, v = x.split('=')
        acc[k] = v
        acc
      end
    else
      @options = {}
    end

    self.last_received_lsn = 0
    self.last_processed_lsn = 0
    self.last_status = Time.now

    replicate(&block) if block
  end

  def connection
    return @connection if @connection

    # Establish Connection
    @connection = PG.connect(@connection_params)
    if @connection.conninfo_hash[:replication] != 'database'
      raise PG::Error.new("Could not establish database-specific replication connection");
    end

    if !@connection
      raise "Unable to create a connection"
    elsif @connection.status == PG::CONNECTION_BAD
      raise "Connection failed: %s" % [ @connection.error_message ]
    end

    ##
    # This SQL statement installs an always-secure search path, so malicious
    # users can't take control.  CREATE of an unqualified name will fail, because
    # this selects no creation schema.  This does not demote pg_temp, so it is
    # suitable where we control the entire FE/BE connection but not suitable in
    # SECURITY DEFINER functions.  This is portable to PostgreSQL 7.3, which
    # introduced schemas.  When connected to an older version from code that
    # might work with the old server, skip this.
    if @connection.server_version >= 100000
      result = @connection.exec("SELECT pg_catalog.set_config('search_path', '', false);")

      if result.result_status != PG::PGRES_TUPLES_OK
        raise "could not clear search_path: %s" % [ @connection.error_message ]
      end
    end

    ##
    # Ensure we have the same value of integer_datetimes (now always "on") as
    # the server we are connecting to.
    tmpparam = @connection.parameter_status("integer_datetimes")
    if !tmpparam
      raise "could not determine server setting for integer_datetimes"
    end

    if tmpparam != "on"
      raise "integer_datetimes compile flag does not match server"
    end

    @connection
  rescue => e
    @connection = nil
    raise e
  end

  def initialize_replication
    #= Replication setup.
    ident = connection.exec('IDENTIFY_SYSTEM;')[0]
    sysid = ident['systemid']

    tli ||= ident['timeline']
    if tli != ident['timeline']
      raise <<-MSG % [ tli, ident['timeline']]
        The timeline on server differs from the specified timeline.

        Specified timeline: %s
        Server timeline: %s
      MSG
    end

    if dbname != ident['dbname']
      raise <<-MSG % [ dbname, ident['dbname']]
        The database on server differs from the specified database.

        Specified database: %s
        Server database: %s
      MSG
    end

    if !xlogpos
      xlogpos = ident['xlogpos']
    end

    query = [ "START_REPLICATION SLOT" ]
    query << PG::Connection.escape_string(slot)
    query << "LOGICAL"
    query << xlogpos

    query_options = []
    @options.each do |k, v|
      query_options << (PG::Connection.quote_ident(k) + " '" + PG::Connection.escape_string(v) + "'")
    end
    if !query_options.empty?
      query << '('
      query << query_options.join(', ')
      query << ')'
    end

    result = connection.exec(query.join(" "))

    if result.result_status != PG::PGRES_COPY_BOTH
      raise PG::InvalidResultStatus.new("Could not send replication command \"%s\"" % [ query ])
    end

    result
  end

  def replicate
    initialize_replication

    loop do
      send_feedback if Time.now - self.last_status > 10
      connection.consume_input

      next if connection.is_busy

      begin
        result = connection.get_copy_data(async: true)
      rescue PG::Error => e
        if e.message == "no COPY in progress"
          next
        else
          raise
        end
      end

      next if !result

      case result[0]
      when 'k' # Keepalive
        a1, a2 = result[1..8].unpack('NN')
        self.last_server_lsn = (a1 << 32) + a2
        send_feedback if result[9] == "\x01"
      when 'w' # WAL data
        a1, a2, b1, b2, c1, c2 = result[1..25].unpack('NNNNNN')
        self.last_received_lsn = (a1 << 32) + a2
        self.last_server_lsn = (b1 << 32) + b2
        timestamp = (c1 << 32) + c2
        data = result[25..-1].force_encoding(connection.internal_encoding)
        yield data
      else
        raise "unrecognized streaming header: \"%c\"" % [ result[0] ]
      end
    end
  ensure
    connection&.finish
  end

  private

  def send_feedback
    self.last_status = Time.now
    timestamp = ((last_status - EPOCH) * 1000000).to_i
    msg = ('r'.codepoints + [
      self.last_received_lsn >> 32,
      self.last_received_lsn,
      self.last_received_lsn >> 32,
      self.last_received_lsn,
      self.last_processed_lsn >> 32,
      self.last_processed_lsn,
      timestamp >> 32,
      timestamp,
      0
    ]).pack('CNNNNNNNNC')

    connection.put_copy_data(msg)
    connection.flush
  end

end

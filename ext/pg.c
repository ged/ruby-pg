/************************************************

  pg.c -

  Author: matz 
  created at: Tue May 13 20:07:35 JST 1997

  Author: ematsu
  modified at: Wed Jan 20 16:41:51 1999

  $Author$
  $Date$
************************************************/

#include "pg.h"
#if defined(HAVE_RUBY_ENCODING_H) && HAVE_RUBY_ENCODING_H
# define M17N_SUPPORTED
#endif

#ifdef _WIN32
	// for O_RDWR and O_BINARY
	#include <fcntl.h>
#endif

#define rb_define_singleton_alias(klass,new,old) rb_define_alias(rb_singleton_class(klass),new,old)

static VALUE rb_cPGconn;
static VALUE rb_cPGresult;
static VALUE rb_ePGError;

static const char *VERSION = "0.11.0";


/* The following functions are part of libpq, but not
 * available from ruby-pg, because they are deprecated,
 * obsolete, or generally not useful:
 *
 * * PQfreemem -- unnecessary: copied to ruby object, then
 *                freed. Ruby object's memory is freed when
 *                it is garbage collected.
 * * PQbinaryTuples -- better to use PQfformat
 * * PQprint -- not very useful
 * * PQsetdb -- not very useful
 * * PQoidStatus -- deprecated, use PQoidValue
 * * PQrequestCancel -- deprecated, use PQcancel
 * * PQfn -- use a prepared statement instead
 * * PQgetline -- deprecated, use PQgetCopyData
 * * PQgetlineAsync -- deprecated, use PQgetCopyData
 * * PQputline -- deprecated, use PQputCopyData
 * * PQputnbytes -- deprecated, use PQputCopyData
 * * PQendcopy -- deprecated, use PQputCopyEnd
 */

/***************************************************************************
 * UTILITY FUNCTIONS
 **************************************************************************/

static void free_pgconn( PGconn * );
static void pgresult_check( VALUE, VALUE );

static PGconn *get_pgconn( VALUE );
static VALUE pgconn_finish( VALUE );
static VALUE pgresult_clear( VALUE );
static VALUE pgresult_aref( VALUE, VALUE );
static VALUE make_column_result_array( VALUE, int );

#ifdef M17N_SUPPORTED
# define ASSOCIATE_INDEX( obj, index_holder ) rb_enc_associate_index((obj), enc_get_index((index_holder)))
static rb_encoding * pgconn_get_client_encoding_as_rb_encoding( PGconn * );
static const char *  pgconn_get_rb_encoding_as_pg_encname( rb_encoding * );
static int enc_get_index( VALUE );
#else
# define ASSOCIATE_INDEX( obj, index_holder ) /* nothing */
#endif

static PQnoticeReceiver default_notice_receiver = NULL;
static PQnoticeProcessor default_notice_processor = NULL;


static void
free_pgconn(PGconn *conn)
{
	if(conn != NULL)
		PQfinish(conn);
}

static void
free_pgresult(PGresult *result)
{
	if(result != NULL)
		PQclear(result);
}

static PGconn*
get_pgconn(VALUE self)
{
	PGconn *conn;
	Data_Get_Struct(self, PGconn, conn);
	if (conn == NULL) rb_raise(rb_ePGError, "not connected");
	return conn;
}

static PGresult*
get_pgresult(VALUE self)
{
	PGresult *result;
	Data_Get_Struct(self, PGresult, result);
	if (result == NULL) rb_raise(rb_ePGError, "result has been cleared");
	return result;
}

#ifdef M17N_SUPPORTED
static VALUE
new_pgresult(PGresult *result, PGconn *conn)
{
	 VALUE val = Data_Wrap_Struct(rb_cPGresult, NULL, free_pgresult, result);
	 rb_encoding *enc = pgconn_get_client_encoding_as_rb_encoding(conn);
	 rb_enc_set_index(val, rb_enc_to_index(enc));
	 return val;
}
#else
static VALUE
new_pgresult(PGresult *result)
{
	return Data_Wrap_Struct(rb_cPGresult, NULL, free_pgresult, result);
}
# define new_pgresult(result, conn) new_pgresult((result))
#endif

/*
 * Raises appropriate exception if PGresult is
 * in a bad state.
 */
static void
pgresult_check(VALUE rb_pgconn, VALUE rb_pgresult)
{
	VALUE error;
	PGconn *conn = get_pgconn(rb_pgconn);
	PGresult *result;
	Data_Get_Struct(rb_pgresult, PGresult, result);

	if(result == NULL)
	{
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
	}
	else
	{
		switch (PQresultStatus(result))
		{
		case PGRES_TUPLES_OK:
		case PGRES_COPY_OUT:
		case PGRES_COPY_IN:
		case PGRES_EMPTY_QUERY:
		case PGRES_COMMAND_OK:
			return;
		case PGRES_BAD_RESPONSE:
		case PGRES_FATAL_ERROR:
		case PGRES_NONFATAL_ERROR:
			error = rb_exc_new2(rb_ePGError, PQresultErrorMessage(result));
			break;
		default:
			error = rb_exc_new2(rb_ePGError,
				"internal error : unknown result status.");
		}
	}

	rb_iv_set(error, "@connection", rb_pgconn);
	rb_iv_set(error, "@result", rb_pgresult);
	rb_exc_raise(error);
	return;
}

static void
notice_receiver_proxy(void *arg, const PGresult *result)
{
	VALUE proc;
	VALUE self = (VALUE)arg;

	if ((proc = rb_iv_get(self, "@notice_receiver")) != Qnil) {
		rb_funcall(proc, rb_intern("call"), 1, 
			Data_Wrap_Struct(rb_cPGresult, NULL, NULL, (PGresult*)result));
	}
	return;
}

static void
notice_processor_proxy(void *arg, const char *message)
{
	VALUE proc;
	VALUE self = (VALUE)arg;

	if ((proc = rb_iv_get(self, "@notice_processor")) != Qnil) {
		rb_funcall(proc, rb_intern("call"), 1, rb_tainted_str_new2(message));
	}
	return;
}


/********************************************************************
 *
 * Document-class: PGError
 *
 * This is the exception class raised when an error is returned from
 * a libpq API call.
 * 
 * The attributes +connection+ and +result+ are set to the connection
 * object and result set object, respectively.
 *
 * If the connection object or result set object is not available from
 * the context in which the error was encountered, it is +nil+.
 */

/********************************************************************
 * 
 * Document-class: PGconn
 *
 * The class to access PostgreSQL RDBMS, based on the libpq interface, 
 * provides convenient OO methods to interact with PostgreSQL.
 *
 * For example, to send query to the database on the localhost:
 *    require 'pg'
 *    conn = PGconn.open(:dbname => 'test')
 *    res = conn.exec('SELECT $1 AS a, $2 AS b, $3 AS c',[1, 2, nil])
 *    # Equivalent to:
 *    #  res  = conn.exec('SELECT 1 AS a, 2 AS b, NULL AS c')
 *
 * See the PGresult class for information on working with the results of a query.
 *
 */

static VALUE
pgconn_alloc(VALUE klass)
{
	return Data_Wrap_Struct(klass, NULL, free_pgconn, NULL);
}

/**************************************************************************
 * PGconn SINGLETON METHODS
 **************************************************************************/

/*
 * Document-method: new
 *
 * call-seq:
 *    PGconn.new -> PGconn
 *    PGconn.new(connection_hash) -> PGconn
 *    PGconn.new(connection_string) -> PGconn
 *    PGconn.new(host, port, options, tty, dbname, user, password) ->  PGconn
 * 
 * Create a connection to the specified server.
 * 
 * [+host+]
 *   server hostname
 * [+hostaddr+]
 *   server address (avoids hostname lookup, overrides +host+)
 * [+port+]
 *   server port number
 * [+dbname+]
 *   connecting database name
 * [+user+]
 *   login user name
 * [+password+]
 *   login password
 * [+connect_timeout+]
 *   maximum time to wait for connection to succeed
 * [+options+]
 *   backend options
 * [+tty+]
 *   (ignored in newer versions of PostgreSQL)
 * [+sslmode+]
 *   (disable|allow|prefer|require)
 * [+krbsrvname+]
 *   kerberos service name
 * [+gsslib+]
 *   GSS library to use for GSSAPI authentication
 * [+service+]
 *   service name to use for additional parameters
 * 
 * Examples:
 * 
 *   # Connect using all defaults
 *   PGconn.connect
 *
 *   # As a Hash
 *   PGconn.connect( :dbname => 'test', :port => 5432 )
 *   
 *   # As a String
 *   PGconn.connect( "dbname=test port=5432" )
 *   
 *   # As an Array
 *   PGconn.connect( nil, 5432, nil, nil, 'test', nil, nil )
 *  
 * If the Ruby default internal encoding is set (i.e., Encoding.default_internal != nil), the
 * connection will have its +client_encoding+ set accordingly.
 * 
 * @raises [PGError] if the connection fails.
 */
static VALUE
pgconn_init(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = NULL;
	VALUE conninfo;
	VALUE error;
#ifdef M17N_SUPPORTED	
	rb_encoding *enc;
	const char *encname;
#endif

	conninfo = rb_funcall2( rb_cPGconn, rb_intern("parse_connect_args"), argc, argv );
	conn = PQconnectdb(StringValuePtr(conninfo));

	if(conn == NULL)
		rb_raise(rb_ePGError, "PQconnectStart() unable to allocate structure");

	Check_Type(self, T_DATA);
	DATA_PTR(self) = conn;

	if (PQstatus(conn) == CONNECTION_BAD) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}

#ifdef M17N_SUPPORTED
	/* If Ruby has its Encoding.default_internal set, set PostgreSQL's client_encoding 
	 * to match */
	if (( enc = rb_default_internal_encoding() )) {
		encname = pgconn_get_rb_encoding_as_pg_encname( enc );
		if ( PQsetClientEncoding(conn, encname) != 0 )
			rb_warn( "Failed to set the default_internal encoding to %s: '%s'",
			         encname, PQerrorMessage(conn) );
	}
#endif

	if (rb_block_given_p()) {
		return rb_ensure(rb_yield, self, pgconn_finish, self);
	}
	return self;
}

/*
 * call-seq:
 *    PGconn.connect_start(connection_hash)       -> PGconn
 *    PGconn.connect_start(connection_string)     -> PGconn
 *    PGconn.connect_start(host, port, options, tty, dbname, login, password) ->  PGconn
 *
 * This is an asynchronous version of PGconn.connect().
 *
 * Use PGconn#connect_poll to poll the status of the connection.
 *
 * NOTE: this does *not* set the connection's +client_encoding+ for you if 
 * Encoding.default_internal is set. To set it after the connection is established, 
 * call PGconn#internal_encoding=. You can also set it automatically by setting 
 * ENV['PGCLIENTENCODING'], or include the 'options' connection parameter.
 * 
 */
static VALUE
pgconn_s_connect_start(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = NULL;
	VALUE rb_conn;
	VALUE conninfo;
	VALUE error;

	/*
	 * PGconn.connect_start must act as both alloc() and initialize()
	 * because it is not invoked by calling new().
	 */
	rb_conn = pgconn_alloc(rb_cPGconn);

	conninfo = rb_funcall2( rb_cPGconn, rb_intern("parse_connect_args"), argc, argv );
	conn = PQconnectStart(StringValuePtr(conninfo));

	if(conn == NULL)
		rb_raise(rb_ePGError, "PQconnectStart() unable to allocate structure");
	if (PQstatus(conn) == CONNECTION_BAD) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}

	Check_Type(rb_conn, T_DATA);
	DATA_PTR(rb_conn) = conn;

	if (rb_block_given_p()) {
		return rb_ensure(rb_yield, self, pgconn_finish, self);
	}
	return rb_conn;
}

/*
 * call-seq:
 *    PGconn.conndefaults() -> Array
 *
 * Returns an array of hashes. Each hash has the keys:
 * [+:keyword+]
 *   the name of the option
 * [+:envvar+]
 *   the environment variable to fall back to
 * [+:compiled+]
 *   the compiled in option as a secondary fallback
 * [+:val+]
 *   the option's current value, or +nil+ if not known
 * [+:label+]
 *   the label for the field
 * [+:dispchar+]
 *   "" for normal, "D" for debug, and "*" for password
 * [+:dispsize+]
 *   field size
 */
static VALUE
pgconn_s_conndefaults(VALUE self)
{
	PQconninfoOption *options = PQconndefaults();
	VALUE ary = rb_ary_new();
	VALUE hash;
	int i = 0;

	for(i = 0; options[i].keyword != NULL; i++) {
		hash = rb_hash_new();
		if(options[i].keyword)
			rb_hash_aset(hash, ID2SYM(rb_intern("keyword")), 
				rb_str_new2(options[i].keyword));
		if(options[i].envvar)
			rb_hash_aset(hash, ID2SYM(rb_intern("envvar")), 
				rb_str_new2(options[i].envvar));
		if(options[i].compiled)
			rb_hash_aset(hash, ID2SYM(rb_intern("compiled")), 
				rb_str_new2(options[i].compiled));
		if(options[i].val)
			rb_hash_aset(hash, ID2SYM(rb_intern("val")), 
				rb_str_new2(options[i].val));
		if(options[i].label)
			rb_hash_aset(hash, ID2SYM(rb_intern("label")), 
				rb_str_new2(options[i].label));
		if(options[i].dispchar)
			rb_hash_aset(hash, ID2SYM(rb_intern("dispchar")), 
				rb_str_new2(options[i].dispchar));
		rb_hash_aset(hash, ID2SYM(rb_intern("dispsize")), 
			INT2NUM(options[i].dispsize));
		rb_ary_push(ary, hash);
	}
	PQconninfoFree(options);
	return ary;
}


/*
 * call-seq:
 *    PGconn.encrypt_password( password, username ) -> String
 *
 * This function is intended to be used by client applications that
 * send commands like: +ALTER USER joe PASSWORD 'pwd'+.
 * The arguments are the cleartext password, and the SQL name 
 * of the user it is for.
 *
 * Return value is the encrypted password.
 */
static VALUE
pgconn_s_encrypt_password(VALUE self, VALUE password, VALUE username)
{
	char *encrypted = NULL;
	VALUE rval = Qnil;

	Check_Type(password, T_STRING);
	Check_Type(username, T_STRING);

	encrypted = PQencryptPassword(StringValuePtr(password), StringValuePtr(username));
	rval = rb_str_new2( encrypted );
	PQfreemem( encrypted );

	OBJ_INFECT( rval, password );
	OBJ_INFECT( rval, username );

	return rval;
}


/*
 * call-seq:
 *    PGconn.isthreadsafe() -> Boolean
 *
 * Returns +true+ if libpq is thread safe, +false+ otherwise.
 */
static VALUE
pgconn_s_isthreadsafe(VALUE self)
{
	return PQisthreadsafe() ? Qtrue : Qfalse;
}

/**************************************************************************
 * PGconn INSTANCE METHODS
 **************************************************************************/

/*
 * call-seq:
 *    conn.connect_poll() -> Fixnum
 *
 * Returns one of:
 * [+PGRES_POLLING_READING+]
 *   wait until the socket is ready to read
 * [+PGRES_POLLING_WRITING+]
 *   wait until the socket is ready to write
 * [+PGRES_POLLING_FAILED+]
 *   the asynchronous connection has failed
 * [+PGRES_POLLING_OK+]
 *   the asynchronous connection is ready
 *
 * Example:
 *   conn = PGconn.connect_start("dbname=mydatabase")
 *   socket = IO.for_fd(conn.socket)
 *   status = conn.connect_poll
 *   while(status != PGconn::PGRES_POLLING_OK) do
 *     # do some work while waiting for the connection to complete
 *     if(status == PGconn::PGRES_POLLING_READING)
 *       if(not select([socket], [], [], 10.0))
 *         raise "Asynchronous connection timed out!"
 *       end
 *     elsif(status == PGconn::PGRES_POLLING_WRITING)
 *       if(not select([], [socket], [], 10.0))
 *         raise "Asynchronous connection timed out!"
 *       end
 *     end
 *     status = conn.connect_poll
 *   end
 *   # now conn.status == CONNECTION_OK, and connection
 *   # is ready.
 */
static VALUE
pgconn_connect_poll(VALUE self)
{
	PostgresPollingStatusType status;
	status = PQconnectPoll(get_pgconn(self));
	return INT2FIX((int)status);
}

/*
 * call-seq:
 *    conn.finish()
 *
 * Closes the backend connection.
 */
static VALUE
pgconn_finish(VALUE self)
{
	PQfinish(get_pgconn(self));
	DATA_PTR(self) = NULL;
	return Qnil;
}

/*
 * call-seq:
 *    conn.reset()
 *
 * Resets the backend connection. This method closes the 
 * backend connection and tries to re-connect.
 */
static VALUE
pgconn_reset(VALUE self)
{
	PQreset(get_pgconn(self));
	return self;
}

/*
 * call-seq:
 *    conn.reset_start() -> nil
 *
 * Initiate a connection reset in a nonblocking manner.
 * This will close the current connection and attempt to
 * reconnect using the same connection parameters.
 * Use PGconn#reset_poll to check the status of the 
 * connection reset.
 */
static VALUE
pgconn_reset_start(VALUE self)
{
	if(PQresetStart(get_pgconn(self)) == 0)
		rb_raise(rb_ePGError, "reset has failed");
	return Qnil;
}

/*
 * call-seq:
 *    conn.reset_poll -> Fixnum
 *
 * Checks the status of a connection reset operation.
 * See PGconn#connect_start and PGconn#connect_poll for
 * usage information and return values.
 */
static VALUE
pgconn_reset_poll(VALUE self)
{
	PostgresPollingStatusType status;
	status = PQresetPoll(get_pgconn(self));
	return INT2FIX((int)status);
}

/*
 * call-seq:
 *    conn.db()
 *
 * Returns the connected database name.
 */
static VALUE
pgconn_db(VALUE self)
{
	char *db = PQdb(get_pgconn(self));
	if (!db) return Qnil;
	return rb_tainted_str_new2(db);
}

/*
 * call-seq:
 *    conn.user()
 *
 * Returns the authenticated user name.
 */
static VALUE
pgconn_user(VALUE self)
{
	char *user = PQuser(get_pgconn(self));
	if (!user) return Qnil;
	return rb_tainted_str_new2(user);
}

/*
 * call-seq:
 *    conn.pass()
 *
 * Returns the authenticated user name.
 */
static VALUE
pgconn_pass(VALUE self)
{
	char *user = PQpass(get_pgconn(self));
	if (!user) return Qnil;
	return rb_tainted_str_new2(user);
}

/*
 * call-seq:
 *    conn.host()
 *
 * Returns the connected server name.
 */
static VALUE
pgconn_host(VALUE self)
{
	char *host = PQhost(get_pgconn(self));
	if (!host) return Qnil;
	return rb_tainted_str_new2(host);
}

/*
 * call-seq:
 *    conn.port()
 *
 * Returns the connected server port number.
 */
static VALUE
pgconn_port(VALUE self)
{
	char* port = PQport(get_pgconn(self));
	return INT2NUM(atol(port));
}

/*
 * call-seq:
 *    conn.tty()
 *
 * Returns the connected pgtty. (Obsolete)
 */
static VALUE
pgconn_tty(VALUE self)
{
	char *tty = PQtty(get_pgconn(self));
	if (!tty) return Qnil;
	return rb_tainted_str_new2(tty);
}

/*
 * call-seq:
 *    conn.options()
 *
 * Returns backend option string.
 */
static VALUE
pgconn_options(VALUE self)
{
	char *options = PQoptions(get_pgconn(self));
	if (!options) return Qnil;
	return rb_tainted_str_new2(options);
}

/*
 * call-seq:
 *    conn.status()
 *
 * Returns status of connection : CONNECTION_OK or CONNECTION_BAD
 */
static VALUE
pgconn_status(VALUE self)
{
	return INT2NUM(PQstatus(get_pgconn(self)));
}

/*
 * call-seq:
 *    conn.transaction_status()
 *
 * returns one of the following statuses:
 *   PQTRANS_IDLE    = 0 (connection idle)
 *   PQTRANS_ACTIVE  = 1 (command in progress)
 *   PQTRANS_INTRANS = 2 (idle, within transaction block)
 *   PQTRANS_INERROR = 3 (idle, within failed transaction)
 *   PQTRANS_UNKNOWN = 4 (cannot determine status)
 */
static VALUE
pgconn_transaction_status(VALUE self)
{
	return INT2NUM(PQtransactionStatus(get_pgconn(self)));
}

/*
 * call-seq:
 *    conn.parameter_status( param_name ) -> String
 *
 * Returns the setting of parameter _param_name_, where
 * _param_name_ is one of
 * * +server_version+
 * * +server_encoding+
 * * +client_encoding+ 
 * * +is_superuser+
 * * +session_authorization+
 * * +DateStyle+
 * * +TimeZone+
 * * +integer_datetimes+
 * * +standard_conforming_strings+
 * 
 * Returns nil if the value of the parameter is not known.
 */
static VALUE
pgconn_parameter_status(VALUE self, VALUE param_name)
{
	const char *ret = PQparameterStatus(get_pgconn(self), 
			StringValuePtr(param_name));
	if(ret == NULL)
		return Qnil;
	else
		return rb_tainted_str_new2(ret);
}

/*
 * call-seq:
 *   conn.protocol_version -> Integer
 *
 * The 3.0 protocol will normally be used when communicating with PostgreSQL 7.4 
 * or later servers; pre-7.4 servers support only protocol 2.0. (Protocol 1.0 is 
 * obsolete and not supported by libpq.)
 */
static VALUE
pgconn_protocol_version(VALUE self)
{
	return INT2NUM(PQprotocolVersion(get_pgconn(self)));
}

/* 
 * call-seq: 
 *   conn.server_version -> Integer
 * 
 * The number is formed by converting the major, minor, and revision
 * numbers into two-decimal-digit numbers and appending them together.
 * For example, version 7.4.2 will be returned as 70402, and version
 * 8.1 will be returned as 80100 (leading zeroes are not shown). Zero
 * is returned if the connection is bad.
 * 
 */
static VALUE
pgconn_server_version(VALUE self)
{
	return INT2NUM(PQserverVersion(get_pgconn(self)));
}

/*
 * call-seq:
 *    conn.error_message -> String
 *
 * Returns the error message about connection.
 */
static VALUE
pgconn_error_message(VALUE self)
{
	char *error = PQerrorMessage(get_pgconn(self));
	if (!error) return Qnil;
	return rb_tainted_str_new2(error);
}

/*
 * call-seq:
 *    conn.socket() -> Fixnum
 *
 * Returns the socket's file descriptor for this connection.
 */
static VALUE
pgconn_socket(VALUE self)
{
	int sd;
	if( (sd = PQsocket(get_pgconn(self))) < 0)
		rb_raise(rb_ePGError, "Can't get socket descriptor");
	return INT2NUM(sd);
}


/*
 * call-seq:
 *    conn.backend_pid() -> Fixnum
 *
 * Returns the process ID of the backend server
 * process for this connection.
 * Note that this is a PID on database server host.
 */
static VALUE
pgconn_backend_pid(VALUE self)
{
	return INT2NUM(PQbackendPID(get_pgconn(self)));
}

/*
 * call-seq:
 *    conn.connection_needs_password() -> Boolean
 *
 * Returns +true+ if the authentication method required a
 * password, but none was available. +false+ otherwise.
 */
static VALUE
pgconn_connection_needs_password(VALUE self)
{
	return PQconnectionNeedsPassword(get_pgconn(self)) ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *    conn.connection_used_password() -> Boolean
 *
 * Returns +true+ if the authentication method used
 * a caller-supplied password, +false+ otherwise.
 */
static VALUE
pgconn_connection_used_password(VALUE self)
{
	return PQconnectionUsedPassword(get_pgconn(self)) ? Qtrue : Qfalse;
}


//TODO get_ssl


/*
 * call-seq:
 *    conn.exec(sql [, params, result_format ] ) -> PGresult
 *    conn.exec(sql [, params, result_format ] ) {|pg_result| block }
 *
 * Sends SQL query request specified by _sql_ to PostgreSQL.
 * Returns a PGresult instance on success.
 * On failure, it raises a PGError exception.
 *
 * +params+ is an optional array of the bind parameters for the SQL query.
 * Each element of the +params+ array may be either:
 *   a hash of the form:
 *     {:value  => String (value of bind parameter)
 *      :type   => Fixnum (oid of type of bind parameter)
 *      :format => Fixnum (0 for text, 1 for binary)
 *     }
 *   or, it may be a String. If it is a string, that is equivalent to the hash:
 *     { :value => <string value>, :type => 0, :format => 0 }
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query. The 0th element of the +params+ array is bound
 * to $1, the 1st element is bound to $2, etc. +nil+ is treated as +NULL+.
 * 
 * If the types are not specified, they will be inferred by PostgreSQL.
 * Instead of specifying type oids, it's recommended to simply add
 * explicit casts in the query to ensure that the right type is used.
 *
 * For example: "SELECT $1::int"
 *
 * The optional +result_format+ should be 0 for text results, 1
 * for binary.
 *
 * If the optional code block is given, it will be passed <i>result</i> as an argument, 
 * and the PGresult object will  automatically be cleared when the block terminates. 
 * In this instance, <code>conn.exec</code> returns the value of the block.
 */
static VALUE
pgconn_exec(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = get_pgconn(self);
	PGresult *result = NULL;
	VALUE rb_pgresult;
	VALUE command, params, in_res_fmt;
	VALUE param, param_type, param_value, param_format;
	VALUE param_value_tmp;
	VALUE sym_type, sym_value, sym_format;
	VALUE gc_array;
	int i=0;
	int nParams;
	Oid *paramTypes;
	char ** paramValues;
	int *paramLengths;
	int *paramFormats;
	int resultFormat;

	rb_scan_args(argc, argv, "12", &command, &params, &in_res_fmt);

	Check_Type(command, T_STRING);

	/* If called with no parameters, use PQexec */
	if(NIL_P(params)) {
		result = PQexec(conn, StringValuePtr(command));
		rb_pgresult = new_pgresult(result, conn);
		pgresult_check(self, rb_pgresult);
		if (rb_block_given_p()) {
			return rb_ensure(rb_yield, rb_pgresult, 
				pgresult_clear, rb_pgresult);
		}
		return rb_pgresult;
	}

	/* If called with parameters, and optionally result_format,
	 * use PQexecParams
	 */
	Check_Type(params, T_ARRAY);

	if(NIL_P(in_res_fmt)) {
		resultFormat = 0;
	}
	else {
		resultFormat = NUM2INT(in_res_fmt);
	}

	gc_array = rb_ary_new();
	rb_gc_register_address(&gc_array);
	sym_type = ID2SYM(rb_intern("type"));
	sym_value = ID2SYM(rb_intern("value"));
	sym_format = ID2SYM(rb_intern("format"));
	nParams = RARRAY_LEN(params);
	paramTypes = ALLOC_N(Oid, nParams); 
	paramValues = ALLOC_N(char *, nParams);
	paramLengths = ALLOC_N(int, nParams);
	paramFormats = ALLOC_N(int, nParams);
	for(i = 0; i < nParams; i++) {
		param = rb_ary_entry(params, i);
		if (TYPE(param) == T_HASH) {
			param_type = rb_hash_aref(param, sym_type);
			param_value_tmp = rb_hash_aref(param, sym_value);
			if(param_value_tmp == Qnil)
				param_value = param_value_tmp;
			else
				param_value = rb_obj_as_string(param_value_tmp);
			param_format = rb_hash_aref(param, sym_format);
		}
		else {
			param_type = Qnil;
			if(param == Qnil)
				param_value = param;
			else
				param_value = rb_obj_as_string(param);
			param_format = Qnil;
		}

		if(param_type == Qnil)
			paramTypes[i] = 0;
		else
			paramTypes[i] = NUM2INT(param_type);

		if(param_value == Qnil) {
			paramValues[i] = NULL;
			paramLengths[i] = 0;
		}
		else {
			Check_Type(param_value, T_STRING);
			/* make sure param_value doesn't get freed by the GC */
			rb_ary_push(gc_array, param_value);
			paramValues[i] = StringValuePtr(param_value);
			paramLengths[i] = RSTRING_LEN(param_value);
		}

		if(param_format == Qnil)
			paramFormats[i] = 0;
		else
			paramFormats[i] = NUM2INT(param_format);
	}

	result = PQexecParams(conn, StringValuePtr(command), nParams, paramTypes, 
		(const char * const *)paramValues, paramLengths, paramFormats, resultFormat);

	rb_gc_unregister_address(&gc_array);

	xfree(paramTypes);
	xfree(paramValues);
	xfree(paramLengths);
	xfree(paramFormats);

	rb_pgresult = new_pgresult(result, conn);
	pgresult_check(self, rb_pgresult);
	if (rb_block_given_p()) {
		return rb_ensure(rb_yield, rb_pgresult, 
			pgresult_clear, rb_pgresult);
	}
	return rb_pgresult;
}

/*
 * call-seq:
 *    conn.prepare(stmt_name, sql [, param_types ] ) -> PGresult
 *
 * Prepares statement _sql_ with name _name_ to be executed later.
 * Returns a PGresult instance on success.
 * On failure, it raises a PGError exception.
 *
 * +param_types+ is an optional parameter to specify the Oids of the 
 * types of the parameters.
 *
 * If the types are not specified, they will be inferred by PostgreSQL.
 * Instead of specifying type oids, it's recommended to simply add
 * explicit casts in the query to ensure that the right type is used.
 *
 * For example: "SELECT $1::int"
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query.
 */
static VALUE
pgconn_prepare(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = get_pgconn(self);
	PGresult *result = NULL;
	VALUE rb_pgresult;
	VALUE name, command, in_paramtypes;
	VALUE param;
	int i = 0;
	int nParams = 0;
	Oid *paramTypes = NULL;

	rb_scan_args(argc, argv, "21", &name, &command, &in_paramtypes);
	Check_Type(name, T_STRING);
	Check_Type(command, T_STRING);

	if(! NIL_P(in_paramtypes)) {
		Check_Type(in_paramtypes, T_ARRAY);
		nParams = RARRAY_LEN(in_paramtypes);
		paramTypes = ALLOC_N(Oid, nParams); 
		for(i = 0; i < nParams; i++) {
			param = rb_ary_entry(in_paramtypes, i);
			Check_Type(param, T_FIXNUM);
			if(param == Qnil)
				paramTypes[i] = 0;
			else
				paramTypes[i] = NUM2INT(param);
		}
	}
	result = PQprepare(conn, StringValuePtr(name), StringValuePtr(command),
			nParams, paramTypes);

	xfree(paramTypes);

	rb_pgresult = new_pgresult(result, conn);
	pgresult_check(self, rb_pgresult);
	return rb_pgresult;
}

/*
 * call-seq:
 *    conn.exec_prepared(statement_name [, params, result_format ] ) -> PGresult
 *    conn.exec_prepared(statement_name [, params, result_format ] ) {|pg_result| block }
 *
 * Execute prepared named statement specified by _statement_name_.
 * Returns a PGresult instance on success.
 * On failure, it raises a PGError exception.
 *
 * +params+ is an array of the optional bind parameters for the 
 * SQL query. Each element of the +params+ array may be either:
 *   a hash of the form:
 *     {:value  => String (value of bind parameter)
 *      :format => Fixnum (0 for text, 1 for binary)
 *     }
 *   or, it may be a String. If it is a string, that is equivalent to the hash:
 *     { :value => <string value>, :format => 0 }
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query. The 0th element of the +params+ array is bound
 * to $1, the 1st element is bound to $2, etc. +nil+ is treated as +NULL+.
 *
 * The optional +result_format+ should be 0 for text results, 1
 * for binary.
 *
 * If the optional code block is given, it will be passed <i>result</i> as an argument, 
 * and the PGresult object will  automatically be cleared when the block terminates. 
 * In this instance, <code>conn.exec_prepared</code> returns the value of the block.
 */
static VALUE
pgconn_exec_prepared(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = get_pgconn(self);
	PGresult *result = NULL;
	VALUE rb_pgresult;
	VALUE name, params, in_res_fmt;
	VALUE param, param_value, param_format;
	VALUE param_value_tmp;
	VALUE sym_value, sym_format;
	VALUE gc_array;
	int i = 0;
	int nParams;
	char ** paramValues;
	int *paramLengths;
	int *paramFormats;
	int resultFormat;


	rb_scan_args(argc, argv, "12", &name, &params, &in_res_fmt);
	Check_Type(name, T_STRING);

	if(NIL_P(params)) {
		params = rb_ary_new2(0);
		resultFormat = 0;
	}
	else {
		Check_Type(params, T_ARRAY);
	}

	if(NIL_P(in_res_fmt)) {
		resultFormat = 0;
	}
	else {
		resultFormat = NUM2INT(in_res_fmt);
	}

	gc_array = rb_ary_new();
	rb_gc_register_address(&gc_array);
	sym_value = ID2SYM(rb_intern("value"));
	sym_format = ID2SYM(rb_intern("format"));
	nParams = RARRAY_LEN(params);
	paramValues = ALLOC_N(char *, nParams);
	paramLengths = ALLOC_N(int, nParams);
	paramFormats = ALLOC_N(int, nParams);
	for(i = 0; i < nParams; i++) {
		param = rb_ary_entry(params, i);
		if (TYPE(param) == T_HASH) {
			param_value_tmp = rb_hash_aref(param, sym_value);
			if(param_value_tmp == Qnil)
				param_value = param_value_tmp;
			else
				param_value = rb_obj_as_string(param_value_tmp);
			param_format = rb_hash_aref(param, sym_format);
		}
		else {
			if(param == Qnil)
				param_value = param;
			else
				param_value = rb_obj_as_string(param);
			param_format = INT2NUM(0);
		}
		if(param_value == Qnil) {
			paramValues[i] = NULL;
			paramLengths[i] = 0;
		}
		else {
			Check_Type(param_value, T_STRING);
			/* make sure param_value doesn't get freed by the GC */
			rb_ary_push(gc_array, param_value);
			paramValues[i] = StringValuePtr(param_value);
			paramLengths[i] = RSTRING_LEN(param_value);
		}

		if(param_format == Qnil)
			paramFormats[i] = 0;
		else
			paramFormats[i] = NUM2INT(param_format);
	}

	result = PQexecPrepared(conn, StringValuePtr(name), nParams, 
		(const char * const *)paramValues, paramLengths, paramFormats, 
		resultFormat);

	rb_gc_unregister_address(&gc_array);

	xfree(paramValues);
	xfree(paramLengths);
	xfree(paramFormats);

	rb_pgresult = new_pgresult(result, conn);
	pgresult_check(self, rb_pgresult);
	if (rb_block_given_p()) {
		return rb_ensure(rb_yield, rb_pgresult, 
			pgresult_clear, rb_pgresult);
	}
	return rb_pgresult;
}

/*
 * call-seq:
 *    conn.describe_prepared( statement_name ) -> PGresult
 *
 * Retrieve information about the prepared statement
 * _statement_name_.
 */
static VALUE
pgconn_describe_prepared(VALUE self, VALUE stmt_name)
{
	PGresult *result;
	VALUE rb_pgresult;
	PGconn *conn = get_pgconn(self);
	char *stmt;
	if(stmt_name == Qnil) {
		stmt = NULL;
	}
	else {
		Check_Type(stmt_name, T_STRING);
		stmt = StringValuePtr(stmt_name);
	}
	result = PQdescribePrepared(conn, stmt);
	rb_pgresult = new_pgresult(result, conn);
	pgresult_check(self, rb_pgresult);
	return rb_pgresult;
}


/*
 * call-seq:
 *    conn.describe_portal( portal_name ) -> PGresult
 *
 * Retrieve information about the portal _portal_name_.
 */
static VALUE
pgconn_describe_portal(self, stmt_name)
	VALUE self, stmt_name;
{
	PGresult *result;
	VALUE rb_pgresult;
	PGconn *conn = get_pgconn(self);
	char *stmt;
	if(stmt_name == Qnil) {
		stmt = NULL;
	}
	else {
		Check_Type(stmt_name, T_STRING);
		stmt = StringValuePtr(stmt_name);
	}
	result = PQdescribePortal(conn, stmt);
	rb_pgresult = new_pgresult(result, conn);
	pgresult_check(self, rb_pgresult);
	return rb_pgresult;
}


/*
 * call-seq:
 *    conn.make_empty_pgresult( status ) -> PGresult
 *
 * Constructs and empty PGresult with status _status_.
 * _status_ may be one of:
 * * +PGRES_EMPTY_QUERY+
 * * +PGRES_COMMAND_OK+
 * * +PGRES_TUPLES_OK+
 * * +PGRES_COPY_OUT+
 * * +PGRES_COPY_IN+
 * * +PGRES_BAD_RESPONSE+
 * * +PGRES_NONFATAL_ERROR+
 * * +PGRES_FATAL_ERROR+
 */
static VALUE
pgconn_make_empty_pgresult(VALUE self, VALUE status)
{
	PGresult *result;
	VALUE rb_pgresult;
	PGconn *conn = get_pgconn(self);
	result = PQmakeEmptyPGresult(conn, NUM2INT(status));
	rb_pgresult = new_pgresult(result, conn);
	pgresult_check(self, rb_pgresult);
	return rb_pgresult;
}


/*
 * call-seq:
 *    conn.escape_string( str ) -> String
 *    PGconn.escape_string( str ) -> String  # DEPRECATED
 *
 * Connection instance method for versions of 8.1 and higher of libpq
 * uses PQescapeStringConn, which is safer. Avoid calling as a class method,
 * the class method uses the deprecated PQescapeString() API function.
 * 
 * Returns a SQL-safe version of the String _str_.
 * This is the preferred way to make strings safe for inclusion in 
 * SQL queries.
 * 
 * Consider using exec_params, which avoids the need for passing values 
 * inside of SQL commands.
 *
 * Encoding of escaped string will be equal to client encoding of connection.
 */
static VALUE
pgconn_s_escape(VALUE self, VALUE string)
{
	char *escaped;
	int size,error;
	VALUE result;
#ifdef M17N_SUPPORTED	
	rb_encoding* enc;
#endif

	Check_Type(string, T_STRING);

	escaped = ALLOC_N(char, RSTRING_LEN(string) * 2 + 1);
	if(rb_obj_class(self) == rb_cPGconn) {
		size = PQescapeStringConn(get_pgconn(self), escaped, 
			RSTRING_PTR(string), RSTRING_LEN(string), &error);
		if(error) {
			xfree(escaped);
			rb_raise(rb_ePGError, "%s", PQerrorMessage(get_pgconn(self)));
		}
	} else {
		size = PQescapeString(escaped, RSTRING_PTR(string),
			RSTRING_LEN(string));
	}
	result = rb_str_new(escaped, size);
	xfree(escaped);
	OBJ_INFECT(result, string);

#ifdef M17N_SUPPORTED
	if(rb_obj_class(self) == rb_cPGconn) {
		enc = pgconn_get_client_encoding_as_rb_encoding(get_pgconn(self));
	} else {
		enc = rb_enc_get(string);
	}
	rb_enc_associate(result, enc);
#endif

	return result;
}

/*
 * call-seq:
 *   conn.escape_bytea( string ) -> String 
 *   PGconn.escape_bytea( string ) -> String # DEPRECATED
 *
 * Connection instance method for versions of 8.1 and higher of libpq
 * uses PQescapeByteaConn, which is safer. Avoid calling as a class method,
 * the class method uses the deprecated PQescapeBytea() API function.
 *
 * Use the instance method version of this function, it is safer than the
 * class method.
 *
 * Escapes binary data for use within an SQL command with the type +bytea+.
 * 
 * Certain byte values must be escaped (but all byte values may be escaped)
 * when used as part of a +bytea+ literal in an SQL statement. In general, to
 * escape a byte, it is converted into the three digit octal number equal to
 * the octet value, and preceded by two backslashes. The single quote (') and
 * backslash (\) characters have special alternative escape sequences.
 * #escape_bytea performs this operation, escaping only the minimally required 
 * bytes.
 * 
 * Consider using exec_params, which avoids the need for passing values inside of 
 * SQL commands.
 */
static VALUE
pgconn_s_escape_bytea(VALUE self, VALUE str)
{
	unsigned char *from, *to;
	size_t from_len, to_len;
	VALUE ret;

	Check_Type(str, T_STRING);
	from      = (unsigned char*)RSTRING_PTR(str);
	from_len  = RSTRING_LEN(str);

	if(rb_obj_class(self) == rb_cPGconn) {
		to = PQescapeByteaConn(get_pgconn(self), from, from_len, &to_len);
	} else {
		to = PQescapeBytea( from, from_len, &to_len);
	}

	ret = rb_str_new((char*)to, to_len - 1);
	OBJ_INFECT(ret, str);
	PQfreemem(to);
	return ret;
}


/*
 * call-seq:
 *   PGconn.unescape_bytea( string )
 *
 * Converts an escaped string representation of binary data into binary data --- the
 * reverse of #escape_bytea. This is needed when retrieving +bytea+ data in text format,
 * but not when retrieving it in binary format.
 *
 */
static VALUE
pgconn_s_unescape_bytea(VALUE self, VALUE str)
{
	unsigned char *from, *to;
	size_t to_len;
	VALUE ret;

	Check_Type(str, T_STRING);
	from = (unsigned char*)StringValuePtr(str);

	to = PQunescapeBytea(from, &to_len);

	ret = rb_str_new((char*)to, to_len);
	OBJ_INFECT(ret, str);
	PQfreemem(to);
	return ret;
}

/*
 * call-seq:
 *    conn.send_query(sql [, params, result_format ] ) -> nil
 *
 * Sends SQL query request specified by _sql_ to PostgreSQL for
 * asynchronous processing, and immediately returns.
 * On failure, it raises a PGError exception.
 *
 * +params+ is an optional array of the bind parameters for the SQL query.
 * Each element of the +params+ array may be either:
 *   a hash of the form:
 *     {:value  => String (value of bind parameter)
 *      :type   => Fixnum (oid of type of bind parameter)
 *      :format => Fixnum (0 for text, 1 for binary)
 *     }
 *   or, it may be a String. If it is a string, that is equivalent to the hash:
 *     { :value => <string value>, :type => 0, :format => 0 }
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query. The 0th element of the +params+ array is bound
 * to $1, the 1st element is bound to $2, etc. +nil+ is treated as +NULL+.
 * 
 * If the types are not specified, they will be inferred by PostgreSQL.
 * Instead of specifying type oids, it's recommended to simply add
 * explicit casts in the query to ensure that the right type is used.
 *
 * For example: "SELECT $1::int"
 *
 * The optional +result_format+ should be 0 for text results, 1
 * for binary.
 */
static VALUE
pgconn_send_query(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = get_pgconn(self);
	int result;
	VALUE command, params, in_res_fmt;
	VALUE param, param_type, param_value, param_format;
	VALUE param_value_tmp;
	VALUE sym_type, sym_value, sym_format;
	VALUE gc_array;
	VALUE error;
	int i=0;
	int nParams;
	Oid *paramTypes;
	char ** paramValues;
	int *paramLengths;
	int *paramFormats;
	int resultFormat;

	rb_scan_args(argc, argv, "12", &command, &params, &in_res_fmt);
	Check_Type(command, T_STRING);

	/* If called with no parameters, use PQsendQuery */
	if(NIL_P(params)) {
		if(PQsendQuery(conn,StringValuePtr(command)) == 0) {
			error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
			rb_iv_set(error, "@connection", self);
			rb_exc_raise(error);
		}
		return Qnil;
	}

	/* If called with parameters, and optionally result_format,
	 * use PQsendQueryParams
	 */
	Check_Type(params, T_ARRAY);

	if(NIL_P(in_res_fmt)) {
		resultFormat = 0;
	}
	else {
		resultFormat = NUM2INT(in_res_fmt);
	}

	gc_array = rb_ary_new();
	rb_gc_register_address(&gc_array);
	sym_type = ID2SYM(rb_intern("type"));
	sym_value = ID2SYM(rb_intern("value"));
	sym_format = ID2SYM(rb_intern("format"));
	nParams = RARRAY_LEN(params);
	paramTypes = ALLOC_N(Oid, nParams); 
	paramValues = ALLOC_N(char *, nParams);
	paramLengths = ALLOC_N(int, nParams);
	paramFormats = ALLOC_N(int, nParams);
	for(i = 0; i < nParams; i++) {
		param = rb_ary_entry(params, i);
		if (TYPE(param) == T_HASH) {
			param_type = rb_hash_aref(param, sym_type);
			param_value_tmp = rb_hash_aref(param, sym_value);
			if(param_value_tmp == Qnil)
				param_value = param_value_tmp;
			else
				param_value = rb_obj_as_string(param_value_tmp);
			param_format = rb_hash_aref(param, sym_format);
		}
		else {
			param_type = INT2NUM(0);
			if(param == Qnil)
				param_value = param;
			else
				param_value = rb_obj_as_string(param);
			param_format = INT2NUM(0);
		}

		if(param_type == Qnil)
			paramTypes[i] = 0;
		else
			paramTypes[i] = NUM2INT(param_type);

		if(param_value == Qnil) {
			paramValues[i] = NULL;
			paramLengths[i] = 0;
		}
		else {
			Check_Type(param_value, T_STRING);
			/* make sure param_value doesn't get freed by the GC */
			rb_ary_push(gc_array, param_value);
			paramValues[i] = StringValuePtr(param_value);
			paramLengths[i] = RSTRING_LEN(param_value);
		}

		if(param_format == Qnil)
			paramFormats[i] = 0;
		else
			paramFormats[i] = NUM2INT(param_format);
	}

	result = PQsendQueryParams(conn, StringValuePtr(command), nParams, paramTypes, 
		(const char * const *)paramValues, paramLengths, paramFormats, resultFormat);

	rb_gc_unregister_address(&gc_array);	

	xfree(paramTypes);
	xfree(paramValues);
	xfree(paramLengths);
	xfree(paramFormats);

	if(result == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}

/*
 * call-seq:
 *    conn.send_prepare( stmt_name, sql [, param_types ] ) -> nil
 *
 * Prepares statement _sql_ with name _name_ to be executed later.
 * Sends prepare command asynchronously, and returns immediately.
 * On failure, it raises a PGError exception.
 *
 * +param_types+ is an optional parameter to specify the Oids of the 
 * types of the parameters.
 *
 * If the types are not specified, they will be inferred by PostgreSQL.
 * Instead of specifying type oids, it's recommended to simply add
 * explicit casts in the query to ensure that the right type is used.
 *
 * For example: "SELECT $1::int"
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query.
 */
static VALUE
pgconn_send_prepare(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = get_pgconn(self);
	int result;
	VALUE name, command, in_paramtypes;
	VALUE param;
	VALUE error;
	int i = 0;
	int nParams = 0;
	Oid *paramTypes = NULL;

	rb_scan_args(argc, argv, "21", &name, &command, &in_paramtypes);
	Check_Type(name, T_STRING);
	Check_Type(command, T_STRING);

	if(! NIL_P(in_paramtypes)) {
		Check_Type(in_paramtypes, T_ARRAY);
		nParams = RARRAY_LEN(in_paramtypes);
		paramTypes = ALLOC_N(Oid, nParams); 
		for(i = 0; i < nParams; i++) {
			param = rb_ary_entry(in_paramtypes, i);
			Check_Type(param, T_FIXNUM);
			if(param == Qnil)
				paramTypes[i] = 0;
			else
				paramTypes[i] = NUM2INT(param);
		}
	}
	result = PQsendPrepare(conn, StringValuePtr(name), StringValuePtr(command),
			nParams, paramTypes);

	xfree(paramTypes);

	if(result == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}

/*
 * call-seq:
 *    conn.send_query_prepared( statement_name [, params, result_format ] )
 *      -> nil
 *
 * Execute prepared named statement specified by _statement_name_
 * asynchronously, and returns immediately.
 * On failure, it raises a PGError exception.
 *
 * +params+ is an array of the optional bind parameters for the 
 * SQL query. Each element of the +params+ array may be either:
 *   a hash of the form:
 *     {:value  => String (value of bind parameter)
 *      :format => Fixnum (0 for text, 1 for binary)
 *     }
 *   or, it may be a String. If it is a string, that is equivalent to the hash:
 *     { :value => <string value>, :format => 0 }
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query. The 0th element of the +params+ array is bound
 * to $1, the 1st element is bound to $2, etc. +nil+ is treated as +NULL+.
 *
 * The optional +result_format+ should be 0 for text results, 1
 * for binary.
 */
static VALUE
pgconn_send_query_prepared(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = get_pgconn(self);
	int result;
	VALUE name, params, in_res_fmt;
	VALUE param, param_value, param_format;
	VALUE param_value_tmp;
	VALUE sym_value, sym_format;
	VALUE gc_array;
	VALUE error;
	int i = 0;
	int nParams;
	char ** paramValues;
	int *paramLengths;
	int *paramFormats;
	int resultFormat;

	rb_scan_args(argc, argv, "12", &name, &params, &in_res_fmt);
	Check_Type(name, T_STRING);

	if(NIL_P(params)) {
		params = rb_ary_new2(0);
		resultFormat = 0;
	}
	else {
		Check_Type(params, T_ARRAY);
	}

	if(NIL_P(in_res_fmt)) {
		resultFormat = 0;
	}
	else {
		resultFormat = NUM2INT(in_res_fmt);
	}

	gc_array = rb_ary_new();
	rb_gc_register_address(&gc_array);
	sym_value = ID2SYM(rb_intern("value"));
	sym_format = ID2SYM(rb_intern("format"));
	nParams = RARRAY_LEN(params);
	paramValues = ALLOC_N(char *, nParams);
	paramLengths = ALLOC_N(int, nParams);
	paramFormats = ALLOC_N(int, nParams);
	for(i = 0; i < nParams; i++) {
		param = rb_ary_entry(params, i);
		if (TYPE(param) == T_HASH) {
			param_value_tmp = rb_hash_aref(param, sym_value);
			if(param_value_tmp == Qnil)
				param_value = param_value_tmp;
			else
				param_value = rb_obj_as_string(param_value_tmp);
			param_format = rb_hash_aref(param, sym_format);
		}
		else {
			if(param == Qnil)
				param_value = param;
			else
				param_value = rb_obj_as_string(param);
			param_format = INT2NUM(0);
		}

		if(param_value == Qnil) {
			paramValues[i] = NULL;
			paramLengths[i] = 0;
		}
		else {
			Check_Type(param_value, T_STRING);
			/* make sure param_value doesn't get freed by the GC */
			rb_ary_push(gc_array, param_value);
			paramValues[i] = StringValuePtr(param_value);
			paramLengths[i] = RSTRING_LEN(param_value);
		}

		if(param_format == Qnil)
			paramFormats[i] = 0;
		else
			paramFormats[i] = NUM2INT(param_format);
	}

	result = PQsendQueryPrepared(conn, StringValuePtr(name), nParams, 
		(const char * const *)paramValues, paramLengths, paramFormats, 
		resultFormat);

	rb_gc_unregister_address(&gc_array);

	xfree(paramValues);
	xfree(paramLengths);
	xfree(paramFormats);

	if(result == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}

/*
 * call-seq:
 *    conn.send_describe_prepared( statement_name ) -> nil
 *
 * Asynchronously send _command_ to the server. Does not block. 
 * Use in combination with +conn.get_result+.
 */
static VALUE
pgconn_send_describe_prepared(VALUE self, VALUE stmt_name)
{
	VALUE error;
	PGconn *conn = get_pgconn(self);
	/* returns 0 on failure */
	if(PQsendDescribePrepared(conn,StringValuePtr(stmt_name)) == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}


/*
 * call-seq:
 *    conn.send_describe_portal( portal_name ) -> nil
 *
 * Asynchronously send _command_ to the server. Does not block. 
 * Use in combination with +conn.get_result+.
 */
static VALUE
pgconn_send_describe_portal(VALUE self, VALUE portal)
{
	VALUE error;
	PGconn *conn = get_pgconn(self);
	/* returns 0 on failure */
	if(PQsendDescribePortal(conn,StringValuePtr(portal)) == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}


/*
 * call-seq:
 *    conn.get_result() -> PGresult
 *    conn.get_result() {|pg_result| block }
 *
 * Blocks waiting for the next result from a call to
 * +PGconn#send_query+ (or another asynchronous command), and returns
 * it. Returns +nil+ if no more results are available.
 *
 * Note: call this function repeatedly until it returns +nil+, or else
 * you will not be able to issue further commands.
 *
 * If the optional code block is given, it will be passed <i>result</i> as an argument, 
 * and the PGresult object will  automatically be cleared when the block terminates. 
 * In this instance, <code>conn.exec</code> returns the value of the block.
 */
static VALUE
pgconn_get_result(VALUE self)
{
	PGconn *conn = get_pgconn(self);
	PGresult *result;
	VALUE rb_pgresult;

	result = PQgetResult(conn);
	if(result == NULL)
		return Qnil;
	rb_pgresult = new_pgresult(result, conn);
	if (rb_block_given_p()) {
		return rb_ensure(rb_yield, rb_pgresult,
			pgresult_clear, rb_pgresult);
	}
	return rb_pgresult;
}

/*
 * call-seq:
 *    conn.consume_input()
 *
 * If input is available from the server, consume it.
 * After calling +consume_input+, you can check +is_busy+
 * or *notifies* to see if the state has changed.
 */
static VALUE
pgconn_consume_input(self)
	VALUE self;
{
	VALUE error;
	PGconn *conn = get_pgconn(self);
	/* returns 0 on error */
	if(PQconsumeInput(conn) == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}

/*
 * call-seq:
 *    conn.is_busy() -> Boolean
 *
 * Returns +true+ if a command is busy, that is, if
 * PQgetResult would block. Otherwise returns +false+.
 */
static VALUE
pgconn_is_busy(self)
	VALUE self;
{
	return PQisBusy(get_pgconn(self)) ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *    conn.setnonblocking(Boolean) -> nil
 *
 * Sets the nonblocking status of the connection. 
 * In the blocking state, calls to PGconn#send_query
 * will block until the message is sent to the server,
 * but will not wait for the query results.
 * In the nonblocking state, calls to PGconn#send_query
 * will return an error if the socket is not ready for
 * writing.
 * Note: This function does not affect PGconn#exec, because
 * that function doesn't return until the server has 
 * processed the query and returned the results.
 * Returns +nil+.
 */
static VALUE
pgconn_setnonblocking(self, state)
	VALUE self, state;
{
	int arg;
	VALUE error;
	PGconn *conn = get_pgconn(self);
	if(state == Qtrue)
		arg = 1;
	else if (state == Qfalse)
		arg = 0;
	else
		rb_raise(rb_eArgError, "Boolean value expected");

	if(PQsetnonblocking(conn, arg) == -1) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}


/*
 * call-seq:
 *    conn.isnonblocking() -> Boolean
 *
 * Returns +true+ if a command is busy, that is, if
 * PQgetResult would block. Otherwise returns +false+.
 */
static VALUE
pgconn_isnonblocking(self)
	VALUE self;
{
	return PQisnonblocking(get_pgconn(self)) ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *    conn.flush() -> Boolean
 *
 * Attempts to flush any queued output data to the server.
 * Returns +true+ if data is successfully flushed, +false+
 * if not (can only return +false+ if connection is
 * nonblocking.
 * Raises PGError exception if some other failure occurred.
 */
static VALUE
pgconn_flush(self)
	VALUE self;
{
	PGconn *conn = get_pgconn(self);
	int ret;
	VALUE error;
	ret = PQflush(conn);
	if(ret == -1) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return (ret) ? Qfalse : Qtrue;
}

/*
 * call-seq:
 *    conn.cancel() -> String
 *
 * Requests cancellation of the command currently being
 * processed. (Only implemented in PostgreSQL >= 8.0)
 *
 * Returns +nil+ on success, or a string containing the
 * error message if a failure occurs.
 */
static VALUE
pgconn_cancel(VALUE self)
{
#ifdef HAVE_PQGETCANCEL
	char errbuf[256];
	PGcancel *cancel;
	VALUE retval;
	int ret;

	cancel = PQgetCancel(get_pgconn(self));
	if(cancel == NULL)
		rb_raise(rb_ePGError,"Invalid connection!");

	ret = PQcancel(cancel, errbuf, 256);
	if(ret == 1)
		retval = Qnil;
	else
		retval = rb_str_new2(errbuf);

	PQfreeCancel(cancel);
	return retval;
#else
	rb_notimplement();
#endif
}


/*
 * call-seq:
 *    conn.notifies()
 *
 * Returns a hash of the unprocessed notifications.
 * If there is no unprocessed notifier, it returns +nil+.
 */
static VALUE
pgconn_notifies(VALUE self)
{
	PGconn* conn = get_pgconn(self);
	PGnotify *notification;
	VALUE hash;
	VALUE sym_relname, sym_be_pid, sym_extra;
	VALUE relname, be_pid, extra;

	sym_relname = ID2SYM(rb_intern("relname"));
	sym_be_pid = ID2SYM(rb_intern("be_pid"));
	sym_extra = ID2SYM(rb_intern("extra"));

	notification = PQnotifies(conn);
	if (notification == NULL) {
		return Qnil;
	}

	hash = rb_hash_new();
	relname = rb_tainted_str_new2(notification->relname);
	be_pid = INT2NUM(notification->be_pid);
	extra = rb_tainted_str_new2(PGNOTIFY_EXTRA(notification));

	rb_hash_aset(hash, sym_relname, relname);
	rb_hash_aset(hash, sym_be_pid, be_pid);
	rb_hash_aset(hash, sym_extra, extra);

	PQfreemem(notification);
	return hash;
}


#ifdef _WIN32
/* 
 * Duplicate the sockets from libpq and create temporary CRT FDs
 */
void create_crt_fd(fd_set *os_set, fd_set *crt_set)
{
	int i;
	crt_set->fd_count = os_set->fd_count;
	for (i = 0; i < os_set->fd_count; i++) {
		WSAPROTOCOL_INFO wsa_pi;
		/* dupicate the SOCKET */
		int r = WSADuplicateSocket(os_set->fd_array[i], GetCurrentProcessId(), &wsa_pi);
		SOCKET s = WSASocket(wsa_pi.iAddressFamily, wsa_pi.iSocketType, wsa_pi.iProtocol, &wsa_pi, 0, 0);
		/* create the CRT fd so ruby can get back to the SOCKET */
		int fd = _open_osfhandle(s, O_RDWR|O_BINARY);
		os_set->fd_array[i] = s;
		crt_set->fd_array[i] = fd;
	}
}

/*
 * Clean up the CRT FDs from create_crt_fd()
 */
void cleanup_crt_fd(fd_set *os_set, fd_set *crt_set)
{
	int i;
	for (i = 0; i < os_set->fd_count; i++) {
		/* cleanup the CRT fd */
		_close(crt_set->fd_array[i]);
		/* cleanup the duplicated SOCKET */
		closesocket(os_set->fd_array[i]);
	}
}
#endif

/*
 * call-seq:
 *    conn.wait_for_notify( [ timeout ] ) -> String
 *    conn.wait_for_notify( [ timeout ] ) { |event, pid| block }
 *
 * Blocks while waiting for notification(s), or until the optional
 * _timeout_ is reached, whichever comes first.  _timeout_ is
 * measured in seconds and can be fractional.
 *
 * Returns +nil+ if _timeout_ is reached, the name of the NOTIFY
 * event otherwise.  If used in block form, passes the name of the
 * NOTIFY +event+ and the generating +pid+ into the block.
 * 
 */
static VALUE
pgconn_wait_for_notify(int argc, VALUE *argv, VALUE self)
{
	PGconn *conn = get_pgconn( self );
	PGnotify *notification;
	int sd = PQsocket( conn );
	int ret;
	struct timeval timeout;
	struct timeval *ptimeout = NULL;
	VALUE timeout_in, relname = Qnil, be_pid = Qnil, extra = Qnil;
	double timeout_sec;
	fd_set sd_rset;
#ifdef _WIN32
	fd_set crt_sd_rset;
#endif

	if ( sd < 0 )
		rb_bug( "PQsocket(conn): couldn't fetch the connection's socket!" );

	if ( rb_scan_args(argc, argv, "01", &timeout_in) == 1 ) {
		timeout_sec = NUM2DBL( timeout_in );
		timeout.tv_sec = (long)timeout_sec;
		timeout.tv_usec = (long)( (timeout_sec - (long)timeout_sec) * 1e6 );
		ptimeout = &timeout;
	}

	/* Check for notifications */
	while ( (notification = PQnotifies(conn)) == NULL ) {
		FD_ZERO( &sd_rset );
		FD_SET( sd, &sd_rset );

#ifdef _WIN32
		create_crt_fd(&sd_rset, &crt_sd_rset);
#endif

		/* Wait for the socket to become readable before checking again */
		ret = rb_thread_select( sd+1, &sd_rset, NULL, NULL, ptimeout );

#ifdef _WIN32
		cleanup_crt_fd(&sd_rset, &crt_sd_rset);
#endif

		if ( ret < 0 )
			rb_sys_fail( 0 );

		/* Return nil if the select timed out */
		if ( ret == 0 ) return Qnil;

		/* Read the socket */
		if ( (ret = PQconsumeInput(conn)) != 1 )
			rb_raise( rb_ePGError, "PQconsumeInput == %d: %s", ret, PQerrorMessage(conn) );
	}

	relname = rb_tainted_str_new2( notification->relname );
	be_pid = INT2NUM( notification->be_pid );
#ifdef HAVE_ST_NOTIFY_EXTRA
	extra = rb_str_new2( notification->extra );
#endif
	PQfreemem( notification );

	if ( rb_block_given_p() )
		rb_yield_values( 3, relname, be_pid, extra );

	return relname;
}


/*
 * call-seq:
 *    conn.put_copy_data( buffer ) -> Boolean
 *
 * Transmits _buffer_ as copy data to the server.
 * Returns true if the data was sent, false if it was
 * not sent (false is only possible if the connection
 * is in nonblocking mode, and this command would block).
 *
 * Raises an exception if an error occurs.
 */
static VALUE
pgconn_put_copy_data(self, buffer)
	VALUE self, buffer;
{
	int ret;
	VALUE error;
	PGconn *conn = get_pgconn(self);
	Check_Type(buffer, T_STRING);

	ret = PQputCopyData(conn, RSTRING_PTR(buffer),
			RSTRING_LEN(buffer));
	if(ret == -1) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return (ret) ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *    conn.put_copy_end( [ error_message ] ) -> Boolean
 *
 * Sends end-of-data indication to the server.
 *
 * _error_message_ is an optional parameter, and if set,
 * forces the COPY command to fail with the string
 * _error_message_.
 *
 * Returns true if the end-of-data was sent, false if it was
 * not sent (false is only possible if the connection
 * is in nonblocking mode, and this command would block).
 */ 
static VALUE
pgconn_put_copy_end(int argc, VALUE *argv, VALUE self)
{
	VALUE str;
	VALUE error;
	int ret;
	char *error_message = NULL;
	PGconn *conn = get_pgconn(self);

	if (rb_scan_args(argc, argv, "01", &str) == 0)
		error_message = NULL;
	else
		error_message = StringValuePtr(str);

	ret = PQputCopyEnd(conn, error_message);
	if(ret == -1) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return (ret) ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *    conn.get_copy_data( [ async = false ] ) -> String
 *
 * Return a string containing one row of data, +nil+
 * if the copy is done, or +false+ if the call would 
 * block (only possible if _async_ is true).
 *
 */
static VALUE
pgconn_get_copy_data(int argc, VALUE *argv, VALUE self )
{
	VALUE async_in;
	VALUE error;
	VALUE result_str;
	int ret;
	int async;
	char *buffer;
	PGconn *conn = get_pgconn(self);

	if (rb_scan_args(argc, argv, "01", &async_in) == 0)
		async = 0;
	else
		async = (async_in == Qfalse || async_in == Qnil) ? 0 : 1;

	ret = PQgetCopyData(conn, &buffer, async);
	if(ret == -2) { // error
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	if(ret == -1) { // No data left
		return Qnil;
	}
	if(ret == 0) { // would block
		return Qfalse;
	}
	result_str = rb_tainted_str_new(buffer, ret);
	PQfreemem(buffer);
	return result_str;
}

/*
 * call-seq:
 *    conn.set_error_verbosity( verbosity ) -> Fixnum
 *
 * Sets connection's verbosity to _verbosity_ and returns
 * the previous setting. Available settings are:
 * * PQERRORS_TERSE
 * * PQERRORS_DEFAULT
 * * PQERRORS_VERBOSE
 */
static VALUE
pgconn_set_error_verbosity(VALUE self, VALUE in_verbosity)
{
	PGconn *conn = get_pgconn(self);
	PGVerbosity verbosity = NUM2INT(in_verbosity);
	return INT2FIX(PQsetErrorVerbosity(conn, verbosity));
}

/*
 * call-seq:
 *    conn.trace( stream ) -> nil
 * 
 * Enables tracing message passing between backend. The 
 * trace message will be written to the stream _stream_,
 * which must implement a method +fileno+ that returns
 * a writable file descriptor.
 */
static VALUE
pgconn_trace(VALUE self, VALUE stream)
{
	VALUE fileno;
	FILE *new_fp;
	int old_fd, new_fd;
	VALUE new_file;

	if(rb_respond_to(stream,rb_intern("fileno")) == Qfalse)
		rb_raise(rb_eArgError, "stream does not respond to method: fileno");

	fileno = rb_funcall(stream, rb_intern("fileno"), 0);
	if(fileno == Qnil)
		rb_raise(rb_eArgError, "can't get file descriptor from stream");

	/* Duplicate the file descriptor and re-open
	 * it. Then, make it into a ruby File object
	 * and assign it to an instance variable.
	 * This prevents a problem when the File
	 * object passed to this function is closed
	 * before the connection object is. */
	old_fd = NUM2INT(fileno);
	new_fd = dup(old_fd);
	new_fp = fdopen(new_fd, "w");

	if(new_fp == NULL)
		rb_raise(rb_eArgError, "stream is not writable");

	new_file = rb_funcall(rb_cIO, rb_intern("new"), 1, INT2NUM(new_fd));
	rb_iv_set(self, "@trace_stream", new_file);

	PQtrace(get_pgconn(self), new_fp);
	return Qnil;
}

/*
 * call-seq:
 *    conn.untrace() -> nil
 * 
 * Disables the message tracing.
 */
static VALUE
pgconn_untrace(VALUE self)
{
	VALUE trace_stream;
	PQuntrace(get_pgconn(self));
	trace_stream = rb_iv_get(self, "@trace_stream");
	rb_funcall(trace_stream, rb_intern("close"), 0);
	rb_iv_set(self, "@trace_stream", Qnil);
	return Qnil;
}

/*
 * call-seq:
 *   conn.set_notice_receiver {|result| ... } -> Proc
 *
 * Notice and warning messages generated by the server are not returned
 * by the query execution functions, since they do not imply failure of
 * the query. Instead they are passed to a notice handling function, and
 * execution continues normally after the handler returns. The default
 * notice handling function prints the message on <tt>stderr</tt>, but the
 * application can override this behavior by supplying its own handling
 * function.
 *
 * This function takes a new block to act as the handler, which should
 * accept a single parameter that will be a PGresult object, and returns 
 * the Proc object previously set, or +nil+ if it was previously the default.
 *
 * If you pass no arguments, it will reset the handler to the default.
 */
static VALUE
pgconn_set_notice_receiver(VALUE self)
{
	VALUE proc, old_proc;
	PGconn *conn = get_pgconn(self);

	/* If default_notice_receiver is unset, assume that the current 
	 * notice receiver is the default, and save it to a global variable. 
	 * This should not be a problem because the default receiver is
	 * always the same, so won't vary among connections.
	 */
	if(default_notice_receiver == NULL)
		default_notice_receiver = PQsetNoticeReceiver(conn, NULL, NULL);

	old_proc = rb_iv_get(self, "@notice_receiver");
	if( rb_block_given_p() ) {
		proc = rb_block_proc();
		PQsetNoticeReceiver(conn, notice_receiver_proxy, (void *)self);
	} else {
		/* if no block is given, set back to default */
		proc = Qnil;
		PQsetNoticeReceiver(conn, default_notice_receiver, NULL);
	}

	rb_iv_set(self, "@notice_receiver", proc);
	return old_proc;
}

/*
 * call-seq:
 *   conn.set_notice_processor {|message| ... } -> Proc
 *
 * Notice and warning messages generated by the server are not returned
 * by the query execution functions, since they do not imply failure of
 * the query. Instead they are passed to a notice handling function, and
 * execution continues normally after the handler returns. The default
 * notice handling function prints the message on <tt>stderr</tt>, but the
 * application can override this behavior by supplying its own handling
 * function.
 *
 * This function takes a new block to act as the handler, which should
 * accept a single parameter that will be a PGresult object, and returns 
 * the Proc object previously set, or +nil+ if it was previously the default.
 *
 * If you pass no arguments, it will reset the handler to the default.
 */
static VALUE
pgconn_set_notice_processor(VALUE self)
{
	VALUE proc, old_proc;
	PGconn *conn = get_pgconn(self);

	/* If default_notice_processor is unset, assume that the current 
	 * notice processor is the default, and save it to a global variable. 
	 * This should not be a problem because the default processor is
	 * always the same, so won't vary among connections.
	 */
	if(default_notice_processor == NULL)
		default_notice_processor = PQsetNoticeProcessor(conn, NULL, NULL);

	old_proc = rb_iv_get(self, "@notice_processor");
	if( rb_block_given_p() ) {
		proc = rb_block_proc();
		PQsetNoticeProcessor(conn, notice_processor_proxy, (void *)self);
	} else {
		/* if no block is given, set back to default */
		proc = Qnil;
		PQsetNoticeProcessor(conn, default_notice_processor, NULL);
	}

	rb_iv_set(self, "@notice_processor", proc);
	return old_proc;
}
/*
 * call-seq:
 *    conn.get_client_encoding() -> String
 * 
 * Returns the client encoding as a String.
 */
static VALUE
pgconn_get_client_encoding(VALUE self)
{
	char *encoding = (char *)pg_encoding_to_char(PQclientEncoding(get_pgconn(self)));
	return rb_tainted_str_new2(encoding);
}

/*
 * call-seq:
 *    conn.set_client_encoding( encoding )
 * 
 * Sets the client encoding to the _encoding_ String.
 */
static VALUE
pgconn_set_client_encoding(VALUE self, VALUE str)
{
	Check_Type(str, T_STRING);
	if ((PQsetClientEncoding(get_pgconn(self), StringValuePtr(str))) == -1){
		rb_raise(rb_ePGError, "invalid encoding name: %s",StringValuePtr(str));
	}
	return Qnil;
}

/*
 * call-seq:
 *    conn.transaction { |conn| ... } -> nil
 *
 * Executes a +BEGIN+ at the start of the block,
 * and a +COMMIT+ at the end of the block, or 
 * +ROLLBACK+ if any exception occurs.
 */
static VALUE
pgconn_transaction(VALUE self)
{
	PGconn *conn = get_pgconn(self);
	PGresult *result;
	VALUE rb_pgresult;
	int status;

	if (rb_block_given_p()) {
		result = PQexec(conn, "BEGIN");
		rb_pgresult = new_pgresult(result, conn);
		pgresult_check(self, rb_pgresult);
		rb_protect(rb_yield, self, &status);
		if(status == 0) {
			result = PQexec(conn, "COMMIT");
			rb_pgresult = new_pgresult(result, conn);
			pgresult_check(self, rb_pgresult);
		}
		else {
			/* exception occurred, ROLLBACK and re-raise */
			result = PQexec(conn, "ROLLBACK");
			rb_pgresult = new_pgresult(result, conn);
			pgresult_check(self, rb_pgresult);
			rb_jump_tag(status);
		}

	}
	else {
		/* no block supplied? */
		rb_raise(rb_eArgError, "Must supply block for PGconn#transaction");
	}
	return Qnil;
}

/*
 * call-seq:
 *    PGconn.quote_ident( str ) -> String
 *    conn.quote_ident( str ) -> String
 *
 * Returns a string that is safe for inclusion in a SQL query as an
 * identifier. Note: this is not a quote function for values, but for
 * identifiers.
 * 
 * For example, in a typical SQL query: <tt>SELECT FOO FROM MYTABLE</tt>
 * The identifier <tt>FOO</tt> is folded to lower case, so it actually
 * means <tt>foo</tt>. If you really want to access the case-sensitive
 * field name <tt>FOO</tt>, use this function like
 * <tt>PGconn.quote_ident('FOO')</tt>, which will return <tt>"FOO"</tt>
 * (with double-quotes). PostgreSQL will see the double-quotes, and
 * it will not fold to lower case.
 * 
 * Similarly, this function also protects against special characters,
 * and other things that might allow SQL injection if the identifier
 * comes from an untrusted source.
 */
static VALUE
pgconn_s_quote_ident(VALUE self, VALUE in_str)
{
	VALUE ret;
	char *str = StringValuePtr(in_str);
	/* result size at most NAMEDATALEN*2 plus surrounding
	 * double-quotes. */
	char buffer[NAMEDATALEN*2+2];
	unsigned int i=0,j=0;

	if(strlen(str) >= NAMEDATALEN) {
		rb_raise(rb_eArgError, 
			"Input string is longer than NAMEDATALEN-1 (%d)",
			NAMEDATALEN-1);
	}
	buffer[j++] = '"';
	for(i = 0; i < strlen(str) && str[i]; i++) {
		if(str[i] == '"') 
			buffer[j++] = '"';
		buffer[j++] = str[i];
	}
	buffer[j++] = '"';
	ret = rb_str_new(buffer,j);
	OBJ_INFECT(ret, in_str);
	return ret;
}


#if defined(HAVE_RUBY_VM_H) && defined(_WIN32)
int rb_w32_wait_events(HANDLE *events, int num, DWORD timeout);
#endif

/*
 * call-seq:
 *    conn.block( [ timeout ] ) -> Boolean
 *
 * Blocks until the server is no longer busy, or until the 
 * optional _timeout_ is reached, whichever comes first.
 * _timeout_ is measured in seconds and can be fractional.
 * 
 * Returns +false+ if _timeout_ is reached, +true+ otherwise.
 * 
 * If +true+ is returned, +conn.is_busy+ will return +false+
 * and +conn.get_result+ will not block.
 */
static VALUE
pgconn_block( int argc, VALUE *argv, VALUE self ) {
	PGconn *conn = get_pgconn(self);
	int sd = PQsocket(conn);
	int ret;

	/* If WIN32 and Ruby 1.9 do not use rb_thread_select() which sometimes hangs 
	 * and does not wait (nor sleep) any time even if timeout is given.
	 * Instead use the Winsock events and rb_w32_wait_events(). */

#if !defined(HAVE_RUBY_VM_H) || !defined(_WIN32)
	struct timeval timeout;
	struct timeval *ptimeout = NULL;
	fd_set sd_rset;
# ifdef _WIN32
	fd_set crt_sd_rset;
# endif
#else // WIN32 and Ruby 1.9
	DWORD timeout_milisec = INFINITY;
	DWORD wait_ret;
	WSAEVENT hEvent;
#endif
	VALUE timeout_in;
	double timeout_sec;

#ifdef _WIN32
# ifdef HAVE_RUBY_VM_H
	hEvent = WSACreateEvent();
# else // Ruby 1.8
	/* Always set a timeout in WIN32, as rb_thread_select() sometimes
	 * doesn't return when a second ruby thread is running although data
	 * could be read. So we use timeout-based polling instead.
	 */
	timeout.tv_sec = 0;
	timeout.tv_usec = 10000; // 10ms
	ptimeout = &timeout;
# endif
#endif

	if ( rb_scan_args(argc, argv, "01", &timeout_in) == 1 ) {
		timeout_sec = NUM2DBL( timeout_in );
#if !defined(HAVE_RUBY_VM_H) || !defined(_WIN32)
		timeout.tv_sec = (long)timeout_sec;
		timeout.tv_usec = (long)((timeout_sec - (long)timeout_sec) * 1e6);
		ptimeout = &timeout;
#else
		timeout_milisec = (DWORD)((timeout_sec - (DWORD)timeout_sec) * 1e3);
#endif
	}

	/* Check for connection errors (PQisBusy is true on connection errors) */
	if( PQconsumeInput( conn )==0 ) {
		rb_raise(rb_ePGError, PQerrorMessage(conn));
	}

	while ( PQisBusy(conn) ) {
#if !defined(HAVE_RUBY_VM_H) || !defined(_WIN32)
		FD_ZERO( &sd_rset );
		FD_SET( sd, &sd_rset );

# ifdef _WIN32
		create_crt_fd(&sd_rset, &crt_sd_rset);
# endif

		ret = rb_thread_select (sd+1, &sd_rset, NULL, NULL, ptimeout );
#else // WIN32 and Ruby 1.9
		if( WSAEventSelect(sd, hEvent, FD_READ|FD_CLOSE)==SOCKET_ERROR ) {
			rb_raise(rb_ePGError, "WSAEventSelect socket error: %d", WSAGetLastError());
		}
		wait_ret = rb_w32_wait_events(&hEvent, 1, 100);
		if( wait_ret==WAIT_TIMEOUT ) {
			ret = 0;
		} else if( wait_ret==WAIT_OBJECT_0 ) {
			ret = 1;
		} else if( wait_ret==WAIT_FAILED ) {
			rb_raise(rb_ePGError, "Wait on socket error (WaitForMultipleObjects): %d", GetLastError());
		} else {
			rb_raise(rb_ePGError, "Wait on socket abandoned (WaitForMultipleObjects)");
		}
#endif

#if !defined(HAVE_RUBY_VM_H) && defined(_WIN32)
		cleanup_crt_fd(&sd_rset, &crt_sd_rset);
#endif

		/* Return false if there was a timeout argument and the select() timed out */
		if ( ret == 0 && argc ) {
#if defined(HAVE_RUBY_VM_H) && defined(_WIN32)
			WSACloseEvent(hEvent);
#endif
			return Qfalse;
		}

		/* Check for connection errors (PQisBusy is true on connection errors) */
		if( PQconsumeInput( conn )==0 ) {
			rb_raise(rb_ePGError, PQerrorMessage(conn));
		}
	} 
#if defined(HAVE_RUBY_VM_H) && defined(_WIN32)
	WSACloseEvent(hEvent);
#endif

	return Qtrue;
}


/*
 * call-seq:
 *    conn.get_last_result( ) -> PGresult
 *
 * This function retrieves all available results
 * on the current connection (from previously issued
 * asynchronous commands like +send_query()+) and
 * returns the last non-NULL result, or +nil+ if no
 * results are available.
 *
 * This function is similar to +PGconn#get_result+
 * except that it is designed to get one and only
 * one result.
 */
static VALUE
pgconn_get_last_result(VALUE self)
{
	PGconn *conn = get_pgconn(self);
	VALUE rb_pgresult = Qnil;
	PGresult *cur, *prev;


	cur = prev = NULL;
	while ((cur = PQgetResult(conn)) != NULL) {
		int status;

		if (prev) PQclear(prev);
		prev = cur;

		status = PQresultStatus(cur);
		if (status == PGRES_COPY_OUT || status == PGRES_COPY_IN)
			break;
	}

	if (prev) {
		rb_pgresult = new_pgresult(prev, conn);
		pgresult_check(self, rb_pgresult);
	}

	return rb_pgresult;
}


/*
 * call-seq:
 *    conn.async_exec(sql [, params, result_format ] ) -> PGresult
 *    conn.async_exec(sql [, params, result_format ] ) {|pg_result| block }
 *
 * This function has the same behavior as +PGconn#exec+,
 * except that it's implemented using asynchronous command 
 * processing and ruby's +rb_thread_select+ in order to 
 * allow other threads to process while waiting for the
 * server to complete the request.
 */
static VALUE
pgconn_async_exec(int argc, VALUE *argv, VALUE self)
{
	VALUE rb_pgresult = Qnil;

	/* remove any remaining results from the queue */
	pgconn_block( 0, NULL, self ); /* wait for input (without blocking) before reading the last result */
	pgconn_get_last_result( self );

	pgconn_send_query( argc, argv, self );
	pgconn_block( 0, NULL, self );
	rb_pgresult = pgconn_get_last_result( self );

	if ( rb_block_given_p() ) {
		return rb_ensure( rb_yield, rb_pgresult, pgresult_clear, rb_pgresult );
	}
	return rb_pgresult;
}


/**************************************************************************
 * LARGE OBJECT SUPPORT
 **************************************************************************/

/*
 * call-seq:
 *    conn.lo_creat( [mode] ) -> Fixnum
 *
 * Creates a large object with mode _mode_. Returns a large object Oid.
 * On failure, it raises PGError exception.
 */
static VALUE
pgconn_locreat(int argc, VALUE *argv, VALUE self)
{
	Oid lo_oid;
	int mode;
	VALUE nmode;
	PGconn *conn = get_pgconn(self);

	if (rb_scan_args(argc, argv, "01", &nmode) == 0)
		mode = INV_READ;
	else
		mode = NUM2INT(nmode);

	lo_oid = lo_creat(conn, mode);
	if (lo_oid == 0)
		rb_raise(rb_ePGError, "lo_creat failed");

	return INT2FIX(lo_oid);
}

/*
 * call-seq:
 *    conn.lo_create( oid ) -> Fixnum
 *
 * Creates a large object with oid _oid_. Returns the large object Oid.
 * On failure, it raises PGError exception.
 */
static VALUE
pgconn_locreate(VALUE self, VALUE in_lo_oid)
{
	Oid ret, lo_oid;
	PGconn *conn = get_pgconn(self);
	lo_oid = NUM2INT(in_lo_oid);

	ret = lo_create(conn, in_lo_oid);
	if (ret == InvalidOid)
		rb_raise(rb_ePGError, "lo_create failed");

	return INT2FIX(ret);
}

/*
 * call-seq:
 *    conn.lo_import(file) -> Fixnum
 *
 * Import a file to a large object. Returns a large object Oid.
 *
 * On failure, it raises a PGError exception.
 */
static VALUE
pgconn_loimport(VALUE self, VALUE filename)
{
	Oid lo_oid;

	PGconn *conn = get_pgconn(self);

	Check_Type(filename, T_STRING);

	lo_oid = lo_import(conn, StringValuePtr(filename));
	if (lo_oid == 0) {
		rb_raise(rb_ePGError, "%s", PQerrorMessage(conn));
	}
	return INT2FIX(lo_oid);
}

/*
 * call-seq:
 *    conn.lo_export( oid, file ) -> nil
 *
 * Saves a large object of _oid_ to a _file_.
 */
static VALUE
pgconn_loexport(VALUE self, VALUE lo_oid, VALUE filename)
{
	PGconn *conn = get_pgconn(self);
	int oid;
	Check_Type(filename, T_STRING);

	oid = NUM2INT(lo_oid);
	if (oid < 0) {
		rb_raise(rb_ePGError, "invalid large object oid %d",oid);
	}

	if (lo_export(conn, oid, StringValuePtr(filename)) < 0) {
		rb_raise(rb_ePGError, "%s", PQerrorMessage(conn));
	}
	return Qnil;
}

/*
 * call-seq:
 *    conn.lo_open( oid, [mode] ) -> Fixnum
 *
 * Open a large object of _oid_. Returns a large object descriptor 
 * instance on success. The _mode_ argument specifies the mode for
 * the opened large object,which is either +INV_READ+, or +INV_WRITE+.
 *
 * If _mode_ is omitted, the default is +INV_READ+.
 */
static VALUE
pgconn_loopen(int argc, VALUE *argv, VALUE self)
{
	Oid lo_oid;
	int fd, mode;
	VALUE nmode, selfid;
	PGconn *conn = get_pgconn(self);

	rb_scan_args(argc, argv, "11", &selfid, &nmode);
	lo_oid = NUM2INT(selfid);
	if(NIL_P(nmode))
		mode = INV_READ;
	else
		mode = NUM2INT(nmode);

	if((fd = lo_open(conn, lo_oid, mode)) < 0) {
		rb_raise(rb_ePGError, "can't open large object: %s", PQerrorMessage(conn));
	}
	return INT2FIX(fd);
}

/*
 * call-seq:
 *    conn.lo_write( lo_desc, buffer ) -> Fixnum
 *
 * Writes the string _buffer_ to the large object _lo_desc_.
 * Returns the number of bytes written.
 */
static VALUE
pgconn_lowrite(VALUE self, VALUE in_lo_desc, VALUE buffer)
{
	int n;
	PGconn *conn = get_pgconn(self);
	int fd = NUM2INT(in_lo_desc);

	Check_Type(buffer, T_STRING);

	if( RSTRING_LEN(buffer) < 0) {
		rb_raise(rb_ePGError, "write buffer zero string");
	}
	if((n = lo_write(conn, fd, StringValuePtr(buffer), 
				RSTRING_LEN(buffer))) < 0) {
		rb_raise(rb_ePGError, "lo_write failed: %s", PQerrorMessage(conn));
	}

	return INT2FIX(n);
}

/*
 * call-seq:
 *    conn.lo_read( lo_desc, len ) -> String
 *
 * Attempts to read _len_ bytes from large object _lo_desc_,
 * returns resulting data.
 */
static VALUE
pgconn_loread(VALUE self, VALUE in_lo_desc, VALUE in_len)
{
	int ret;
  PGconn *conn = get_pgconn(self);
	int len = NUM2INT(in_len);
	int lo_desc = NUM2INT(in_lo_desc);
	VALUE str;
	char *buffer;

  buffer = ALLOC_N(char, len);
	if(buffer == NULL)
		rb_raise(rb_eNoMemError, "ALLOC failed!");

	if (len < 0){
		rb_raise(rb_ePGError,"nagative length %d given", len);
	}

	if((ret = lo_read(conn, lo_desc, buffer, len)) < 0)
		rb_raise(rb_ePGError, "lo_read failed");

	if(ret == 0) {
		xfree(buffer);
		return Qnil;
	}

	str = rb_tainted_str_new(buffer, ret);
	xfree(buffer);

	return str;
}


/*
 * call-seq:
 *    conn.lo_lseek( lo_desc, offset, whence ) -> Fixnum
 *
 * Move the large object pointer _lo_desc_ to offset _offset_.
 * Valid values for _whence_ are +SEEK_SET+, +SEEK_CUR+, and +SEEK_END+.
 * (Or 0, 1, or 2.)
 */
static VALUE
pgconn_lolseek(VALUE self, VALUE in_lo_desc, VALUE offset, VALUE whence)
{
	PGconn *conn = get_pgconn(self);
	int lo_desc = NUM2INT(in_lo_desc);
	int ret;

	if((ret = lo_lseek(conn, lo_desc, NUM2INT(offset), NUM2INT(whence))) < 0) {
		rb_raise(rb_ePGError, "lo_lseek failed");
	}

	return INT2FIX(ret);
}

/*
 * call-seq:
 *    conn.lo_tell( lo_desc ) -> Fixnum
 *
 * Returns the current position of the large object _lo_desc_.
 */
static VALUE
pgconn_lotell(VALUE self, VALUE in_lo_desc)
{
	int position;
	PGconn *conn = get_pgconn(self);
	int lo_desc = NUM2INT(in_lo_desc);

	if((position = lo_tell(conn, lo_desc)) < 0)
		rb_raise(rb_ePGError,"lo_tell failed");

	return INT2FIX(position);
}

/*
 * call-seq:
 *    conn.lo_truncate( lo_desc, len ) -> nil
 *
 * Truncates the large object _lo_desc_ to size _len_.
 */
static VALUE
pgconn_lotruncate(VALUE self, VALUE in_lo_desc, VALUE in_len)
{
	PGconn *conn = get_pgconn(self);
	int lo_desc = NUM2INT(in_lo_desc);
	size_t len = NUM2INT(in_len);

	if(lo_truncate(conn,lo_desc,len) < 0)
		rb_raise(rb_ePGError,"lo_truncate failed");

	return Qnil;
}

/*
 * call-seq:
 *    conn.lo_close( lo_desc ) -> nil
 *
 * Closes the postgres large object of _lo_desc_.
 */
static VALUE
pgconn_loclose(VALUE self, VALUE in_lo_desc)
{
	PGconn *conn = get_pgconn(self);
	int lo_desc = NUM2INT(in_lo_desc);

	if(lo_close(conn,lo_desc) < 0)
		rb_raise(rb_ePGError,"lo_close failed");

	return Qnil;
}

/*
 * call-seq:
 *    conn.lo_unlink( oid ) -> nil
 *
 * Unlinks (deletes) the postgres large object of _oid_.
 */
static VALUE
pgconn_lounlink(VALUE self, VALUE in_oid)
{
	PGconn *conn = get_pgconn(self);
	int oid = NUM2INT(in_oid);

	if (oid < 0)
		rb_raise(rb_ePGError, "invalid oid %d",oid);

	if(lo_unlink(conn,oid) < 0)
		rb_raise(rb_ePGError,"lo_unlink failed");

	return Qnil;
}

/********************************************************************
 * 
 * Document-class: PGresult
 *
 * The class to represent the query result tuples (rows). 
 * An instance of this class is created as the result of every query.
 * You may need to invoke the #clear method of the instance when finished with
 * the result for better memory performance.
 *
 * Example:
 *    require 'pg'
 *    conn = PGconn.open(:dbname => 'test')
 *    res  = conn.exec('SELECT 1 AS a, 2 AS b, NULL AS c')
 *    res.getvalue(0,0) # '1'
 *    res[0]['b']       # '2'
 *    res[0]['c']       # nil
 *  
 */

/**************************************************************************
 * PGresult INSTANCE METHODS
 **************************************************************************/

/*
 * call-seq:
 *    res.result_status() -> Fixnum
 *
 * Returns the status of the query. The status value is one of:
 * * +PGRES_EMPTY_QUERY+
 * * +PGRES_COMMAND_OK+
 * * +PGRES_TUPLES_OK+
 * * +PGRES_COPY_OUT+
 * * +PGRES_COPY_IN+
 * * +PGRES_BAD_RESPONSE+
 * * +PGRES_NONFATAL_ERROR+
 * * +PGRES_FATAL_ERROR+
 */
static VALUE
pgresult_result_status(VALUE self)
{
	return INT2FIX(PQresultStatus(get_pgresult(self)));
}

/*
 * call-seq:
 *    res.res_status( status ) -> String
 *
 * Returns the string representation of status +status+.
 *
*/
static VALUE
pgresult_res_status(VALUE self, VALUE status)
{
	VALUE ret = rb_tainted_str_new2(PQresStatus(NUM2INT(status)));
	ASSOCIATE_INDEX(ret, self);
	return ret;
}

/*
 * call-seq:
 *    res.result_error_message() -> String
 *
 * Returns the error message of the command as a string. 
 */
static VALUE
pgresult_result_error_message(VALUE self)
{
	VALUE ret = rb_tainted_str_new2(PQresultErrorMessage(get_pgresult(self)));
	ASSOCIATE_INDEX(ret, self);
	return ret;
}

/*
 * call-seq:
 *    res.result_error_field(fieldcode) -> String
 *
 * Returns the individual field of an error.
 *
 * +fieldcode+ is one of:
 * * +PG_DIAG_SEVERITY+
 * * +PG_DIAG_SQLSTATE+
 * * +PG_DIAG_MESSAGE_PRIMARY+
 * * +PG_DIAG_MESSAGE_DETAIL+
 * * +PG_DIAG_MESSAGE_HINT+
 * * +PG_DIAG_STATEMENT_POSITION+
 * * +PG_DIAG_INTERNAL_POSITION+
 * * +PG_DIAG_INTERNAL_QUERY+
 * * +PG_DIAG_CONTEXT+
 * * +PG_DIAG_SOURCE_FILE+
 * * +PG_DIAG_SOURCE_LINE+
 * * +PG_DIAG_SOURCE_FUNCTION+
 */
static VALUE
pgresult_result_error_field(VALUE self, VALUE field)
{
	PGresult *result = get_pgresult(self);
	int fieldcode = NUM2INT(field);
	VALUE ret = rb_tainted_str_new2(PQresultErrorField(result,fieldcode));
	ASSOCIATE_INDEX(ret, self);
	return ret;
}

/*
 * call-seq:
 *    res.clear() -> nil
 *
 * Clears the PGresult object as the result of the query.
 */
static VALUE
pgresult_clear(VALUE self)
{
	PQclear(get_pgresult(self));
	DATA_PTR(self) = NULL;
	return Qnil;
}

/*
 * call-seq:
 *    res.ntuples() -> Fixnum
 *
 * Returns the number of tuples in the query result.
 */
static VALUE
pgresult_ntuples(VALUE self)
{
	return INT2FIX(PQntuples(get_pgresult(self)));
}

/*
 * call-seq:
 *    res.nfields() -> Fixnum
 *
 * Returns the number of columns in the query result.
 */
static VALUE
pgresult_nfields(VALUE self)
{
	return INT2NUM(PQnfields(get_pgresult(self)));
}

/*
 * call-seq:
 *    res.fname( index ) -> String
 *
 * Returns the name of the column corresponding to _index_.
 */
static VALUE
pgresult_fname(VALUE self, VALUE index)
{
	VALUE fname;
	PGresult *result;
	int i = NUM2INT(index);

	result = get_pgresult(self);
	if (i < 0 || i >= PQnfields(result)) {
		rb_raise(rb_eArgError,"invalid field number %d", i);
	}
	fname = rb_tainted_str_new2(PQfname(result, i));
	ASSOCIATE_INDEX(fname, self);
	return fname;
}

/*
 * call-seq:
 *    res.fnumber( name ) -> Fixnum
 *
 * Returns the index of the field specified by the string _name_.
 *
 * Raises an ArgumentError if the specified _name_ isn't one of the field names;
 * raises a TypeError if _name_ is not a String.
 */
static VALUE
pgresult_fnumber(VALUE self, VALUE name)
{
	int n;

	Check_Type(name, T_STRING);

	n = PQfnumber(get_pgresult(self), StringValuePtr(name));
	if (n == -1) {
		rb_raise(rb_eArgError,"Unknown field: %s", StringValuePtr(name));
	}
	return INT2FIX(n);
}

/*
 * call-seq:
 *    res.ftable( column_number ) -> Fixnum
 *
 * Returns the Oid of the table from which the column _column_number_
 * was fetched.
 *
 * Raises ArgumentError if _column_number_ is out of range or if
 * the Oid is undefined for that column.
 */
static VALUE
pgresult_ftable(VALUE self, VALUE column_number)
{
	Oid n ;
	int col_number = NUM2INT(column_number);
	PGresult *pgresult = get_pgresult(self);

	if( col_number < 0 || col_number >= PQnfields(pgresult)) 
		rb_raise(rb_eArgError,"Invalid column index: %d", col_number);

	n = PQftable(pgresult, col_number);
	return INT2FIX(n);
}

/*
 * call-seq:
 *    res.ftablecol( column_number ) -> Fixnum
 *
 * Returns the column number (within its table) of the table from 
 * which the column _column_number_ is made up.
 *
 * Raises ArgumentError if _column_number_ is out of range or if
 * the column number from its table is undefined for that column.
 */
static VALUE
pgresult_ftablecol(VALUE self, VALUE column_number)
{
	int col_number = NUM2INT(column_number);
	PGresult *pgresult = get_pgresult(self);

	int n;

	if( col_number < 0 || col_number >= PQnfields(pgresult)) 
		rb_raise(rb_eArgError,"Invalid column index: %d", col_number);

	n = PQftablecol(pgresult, col_number);
	return INT2FIX(n);
}

/*
 * call-seq:
 *    res.fformat( column_number ) -> Fixnum
 *
 * Returns the format (0 for text, 1 for binary) of column
 * _column_number_.
 * 
 * Raises ArgumentError if _column_number_ is out of range.
 */
static VALUE
pgresult_fformat(VALUE self, VALUE column_number)
{
	PGresult *result = get_pgresult(self);
	int fnumber = NUM2INT(column_number);
	if (fnumber < 0 || fnumber >= PQnfields(result)) {
		rb_raise(rb_eArgError, "Column number is out of range: %d", 
			fnumber);
	}
	return INT2FIX(PQfformat(result, fnumber));
}

/*
 * call-seq:
 *    res.ftype( column_number )
 *
 * Returns the data type associated with _column_number_.
 *
 * The integer returned is the internal +OID+ number (in PostgreSQL)
 * of the type. To get a human-readable value for the type, use the
 * returned OID and the field's #fmod value with the format_type() SQL 
 * function:
 * 
 *   # Get the type of the second column of the result 'res'
 *   typename = conn.
 *     exec( "SELECT format_type($1,$2)", [res.ftype(1), res.fmod(1)] ).
 *     getvalue( 0, 0 )
 * 
 * Raises an ArgumentError if _column_number_ is out of range.
 */
static VALUE
pgresult_ftype(VALUE self, VALUE index)
{
	PGresult* result = get_pgresult(self);
	int i = NUM2INT(index);
	if (i < 0 || i >= PQnfields(result)) {
		rb_raise(rb_eArgError, "invalid field number %d", i);
	}
	return INT2NUM(PQftype(result, i));
}

/*
 * call-seq:
 *    res.fmod( column_number )
 *
 * Returns the type modifier associated with column _column_number_. See 
 * the #ftype method for an example of how to use this.
 * 
 * Raises an ArgumentError if _column_number_ is out of range.
 */
static VALUE
pgresult_fmod(VALUE self, VALUE column_number)
{
	PGresult *result = get_pgresult(self);
	int fnumber = NUM2INT(column_number);
	int modifier;
	if (fnumber < 0 || fnumber >= PQnfields(result)) {
		rb_raise(rb_eArgError, "Column number is out of range: %d", 
			fnumber);
	}
	modifier = PQfmod(result,fnumber);

	return INT2NUM(modifier);
}

/*
 * call-seq:
 *    res.fsize( index )
 *
 * Returns the size of the field type in bytes.  Returns <tt>-1</tt> if the field is variable sized.
 *
 *   res = conn.exec("SELECT myInt, myVarChar50 FROM foo")
 *   res.size(0) => 4
 *   res.size(1) => -1
 */
static VALUE
pgresult_fsize(VALUE self, VALUE index)
{
	PGresult *result;
	int i = NUM2INT(index);

	result = get_pgresult(self);
	if (i < 0 || i >= PQnfields(result)) {
		rb_raise(rb_eArgError,"invalid field number %d", i);
	}
	return INT2NUM(PQfsize(result, i));
}

/*
 * call-seq:
 *    res.getvalue( tup_num, field_num )
 *
 * Returns the value in tuple number _tup_num_, field _field_num_,
 * or +nil+ if the field is +NULL+.
 */
static VALUE
pgresult_getvalue(VALUE self, VALUE tup_num, VALUE field_num)
{
	VALUE ret;
	PGresult *result;
	int i = NUM2INT(tup_num);
	int j = NUM2INT(field_num);

	result = get_pgresult(self);
	if(i < 0 || i >= PQntuples(result)) {
		rb_raise(rb_eArgError,"invalid tuple number %d", i);
	}
	if(j < 0 || j >= PQnfields(result)) {
		rb_raise(rb_eArgError,"invalid field number %d", j);
	}
	if(PQgetisnull(result, i, j))
		return Qnil;
	ret = rb_tainted_str_new(PQgetvalue(result, i, j), 
				PQgetlength(result, i, j));
	ASSOCIATE_INDEX(ret, self);
	return ret;
}

/*
 * call-seq:
 *    res.getisnull(tuple_position, field_position) -> boolean
 *
 * Returns +true+ if the specified value is +nil+; +false+ otherwise.
 */
static VALUE
pgresult_getisnull(VALUE self, VALUE tup_num, VALUE field_num)
{
	PGresult *result;
	int i = NUM2INT(tup_num);
	int j = NUM2INT(field_num);

	result = get_pgresult(self);
	if (i < 0 || i >= PQntuples(result)) {
		rb_raise(rb_eArgError,"invalid tuple number %d", i);
	}
	if (j < 0 || j >= PQnfields(result)) {
		rb_raise(rb_eArgError,"invalid field number %d", j);
	}
	return PQgetisnull(result, i, j) ? Qtrue : Qfalse;
}

/*
 * call-seq:
 *    res.getlength( tup_num, field_num ) -> Fixnum
 *
 * Returns the (String) length of the field in bytes.
 *
 * Equivalent to <tt>res.value(<i>tup_num</i>,<i>field_num</i>).length</tt>.
 */
static VALUE
pgresult_getlength(VALUE self, VALUE tup_num, VALUE field_num)
{
	PGresult *result;
	int i = NUM2INT(tup_num);
	int j = NUM2INT(field_num);

	result = get_pgresult(self);
	if (i < 0 || i >= PQntuples(result)) {
		rb_raise(rb_eArgError,"invalid tuple number %d", i);
	}
	if (j < 0 || j >= PQnfields(result)) {
		rb_raise(rb_eArgError,"invalid field number %d", j);
	}
	return INT2FIX(PQgetlength(result, i, j));
}

/*
 * call-seq:
 *    res.nparams() -> Fixnum
 *
 * Returns the number of parameters of a prepared statement.
 * Only useful for the result returned by conn.describePrepared
 */
static VALUE
pgresult_nparams(VALUE self)
{
	PGresult *result;

	result = get_pgresult(self);
	return INT2FIX(PQnparams(result));
}

/*
 * call-seq:
 *    res.paramtype( param_number ) -> Oid
 *
 * Returns the Oid of the data type of parameter _param_number_.
 * Only useful for the result returned by conn.describePrepared
 */
static VALUE
pgresult_paramtype(VALUE self, VALUE param_number)
{
	PGresult *result;

	result = get_pgresult(self);
	return INT2FIX(PQparamtype(result,NUM2INT(param_number)));
}

/*
 * call-seq:
 *    res.cmd_status() -> String
 *
 * Returns the status string of the last query command.
 */
static VALUE
pgresult_cmd_status(VALUE self)
{
	VALUE ret = rb_tainted_str_new2(PQcmdStatus(get_pgresult(self)));
	ASSOCIATE_INDEX(ret, self);
	return ret;
}

/*
 * call-seq:
 *    res.cmd_tuples() -> Fixnum
 *
 * Returns the number of tuples (rows) affected by the SQL command.
 *
 * If the SQL command that generated the PGresult was not one of:
 * * +INSERT+
 * * +UPDATE+
 * * +DELETE+
 * * +MOVE+
 * * +FETCH+
 * or if no tuples were affected, <tt>0</tt> is returned.
 */
static VALUE
pgresult_cmd_tuples(VALUE self)
{
	long n;
	n = strtol(PQcmdTuples(get_pgresult(self)),NULL, 10);
	return INT2NUM(n);
}

/*
 * call-seq:
 *    res.oid_value() -> Fixnum
 *
 * Returns the +oid+ of the inserted row if applicable,
 * otherwise +nil+.
 */
static VALUE
pgresult_oid_value(VALUE self)
{
	Oid n = PQoidValue(get_pgresult(self));
	if (n == InvalidOid)
		return Qnil;
	else
		return INT2FIX(n);
}

/* Utility methods not in libpq */

/*
 * call-seq:
 *    res[ n ] -> Hash
 *
 * Returns tuple _n_ as a hash. 
 */
static VALUE
pgresult_aref(VALUE self, VALUE index)
{
	PGresult *result = get_pgresult(self);
	int tuple_num = NUM2INT(index);
	int field_num;
	VALUE fname,val;
	VALUE tuple;

	if ( tuple_num < 0 || tuple_num >= PQntuples(result) )
		rb_raise( rb_eIndexError, "Index %d is out of range", tuple_num );

	tuple = rb_hash_new();
	for ( field_num = 0; field_num < PQnfields(result); field_num++ ) {
		fname = rb_tainted_str_new2( PQfname(result,field_num) );
		ASSOCIATE_INDEX(fname, self);
		if ( PQgetisnull(result, tuple_num, field_num) ) {
			rb_hash_aset( tuple, fname, Qnil );
		}
		else {
			val = rb_tainted_str_new( PQgetvalue(result, tuple_num, field_num ),
			                          PQgetlength(result, tuple_num, field_num) );

			/* associate client encoding for text format only */
			if ( 0 == PQfformat(result, field_num) ) {
				ASSOCIATE_INDEX( val, self );
			} else {
#ifdef M17N_SUPPORTED
				rb_enc_associate( val, rb_ascii8bit_encoding() );
#endif
			}
			rb_hash_aset( tuple, fname, val );
		}
	}
	return tuple;
}


/*
 * call-seq:
 *    res.values -> Array
 *
 * Returns all tuples as an array of arrays.
 */
static VALUE
pgresult_values(VALUE self, VALUE index)
{
	PGresult* result = (PGresult*) get_pgresult(self);
	int row;
	int field;
	int num_rows = PQntuples(result);
	int num_fields = PQnfields(result);
	VALUE ary = rb_ary_new2(num_rows);

	for ( row = 0; row < num_rows; row++ ) {
		/* create new row */
		VALUE new_row = rb_ary_new2(num_fields);

		/* add to return array */
		rb_ary_store( ary, row, new_row );

		/* populate it */
		for ( field = 0; field < num_fields; field++ ) {
			if ( PQgetisnull(result, row, field) ) {
				rb_ary_store( new_row, field, Qnil );
			}
			else {
				VALUE val = rb_tainted_str_new( PQgetvalue(result, row, field), 
				                                PQgetlength(result, row, field) );

				/* associate client encoding for text format only */
				if ( 0 == PQfformat(result, field) ) {
					ASSOCIATE_INDEX( val, self );
				} else {
#ifdef M17N_SUPPORTED
					rb_enc_associate( val, rb_ascii8bit_encoding() );
#endif
				}

				rb_ary_store( new_row, field, val );
			}
		}
	}
	return ary;
}


/*
 *  call-seq:
 *     res.column_values( n )   -> array
 *
 *  Returns an Array of the values from the nth column of each 
 *  tuple in the result.
 *
 */
static VALUE
pgresult_column_values(VALUE self, VALUE index)
{
	int col = NUM2INT( index );
	return make_column_result_array( self, col );
}


/*
 *  call-seq:
 *     res.field_values( field )   -> array
 *
 *  Returns an Array of the values from the given _field_ of each tuple in the result.
 *
 */
static VALUE
pgresult_field_values( VALUE self, VALUE field )
{
	PGresult *result = get_pgresult( self );
	const char *fieldname = RSTRING_PTR( field );
	int fnum = PQfnumber( result, fieldname );

	if ( fnum < 0 )
		rb_raise( rb_eIndexError, "no such field '%s' in result", fieldname );

	return make_column_result_array( self, fnum );
}


/* 
 * Make a Ruby array out of the encoded values from the specified
 * column in the given result.
 */
static VALUE
make_column_result_array( VALUE self, int col )
{
	PGresult *result = get_pgresult( self );
	int row = PQntuples( result );
	VALUE ary = rb_ary_new2( row );
	VALUE val = Qnil;

	if ( col >= PQnfields(result) )
		rb_raise( rb_eIndexError, "no column %d in result", col );

	while ( row-- ) {
		val = rb_tainted_str_new( PQgetvalue(result, row, col),
		                          PQgetlength(result, row, col) );

		/* associate client encoding for text format only */
		if ( 0 == PQfformat(result, col) ) { 
			ASSOCIATE_INDEX( val, self );
		} else {
#ifdef M17N_SUPPORTED
			rb_enc_associate( val, rb_ascii8bit_encoding() );
#endif
		}

		rb_ary_store( ary, row, val );
	}

	return ary;
}


/*
 * call-seq:
 *    res.each{ |tuple| ... }
 *
 * Invokes block for each tuple in the result set.
 */
static VALUE
pgresult_each(VALUE self)
{
	PGresult *result = get_pgresult(self);
	int tuple_num;

	for(tuple_num = 0; tuple_num < PQntuples(result); tuple_num++) {
		rb_yield(pgresult_aref(self, INT2NUM(tuple_num)));
	}
	return self;
}

/*
 * call-seq:
 *    res.fields() -> Array
 *
 * Returns an array of Strings representing the names of the fields in the result.
 */
static VALUE
pgresult_fields(VALUE self)
{
	PGresult *result;
	VALUE ary;
	int n, i;

	result = get_pgresult(self);
	n = PQnfields(result);
	ary = rb_ary_new2(n);
	for (i=0;i<n;i++) {
		VALUE val = rb_tainted_str_new2(PQfname(result, i));
		ASSOCIATE_INDEX(val, self);
		rb_ary_push(ary, val);
	}
	return ary;
}


#ifdef M17N_SUPPORTED
/**
 * The mapping from canonical encoding names in PostgreSQL to ones in Ruby.
 */
static const char * const (enc_pg2ruby_mapping[][2]) = {
	    {"BIG5",          "Big5"        },
	    {"EUC_CN",        "GB2312"      },
	    {"EUC_JP",        "EUC-JP"      },
	    {"EUC_JIS_2004",  "EUC-JP"      },
	    {"EUC_KR",        "EUC-KR"      },
	    {"EUC_TW",        "EUC-TW"      },
	    {"GB18030",       "GB18030"     },
	    {"GBK",           "GBK"         },
	    {"ISO_8859_5",    "ISO-8859-5"  },
	    {"ISO_8859_6",    "ISO-8859-6"  },
	    {"ISO_8859_7",    "ISO-8859-7"  },
	    {"ISO_8859_8",    "ISO-8859-8"  },
	    /* {"JOHAB",         "JOHAB"       }, dummy */
	    {"KOI8",          "KOI8-R"      },
	    {"KOI8R",         "KOI8-R"      },
	    {"KOI8U",         "KOI8-U"      },
	    {"LATIN1",        "ISO-8859-1"  },
	    {"LATIN2",        "ISO-8859-2"  },
	    {"LATIN3",        "ISO-8859-3"  },
	    {"LATIN4",        "ISO-8859-4"  },
	    {"LATIN5",        "ISO-8859-5"  },
	    {"LATIN6",        "ISO-8859-6"  },
	    {"LATIN7",        "ISO-8859-7"  },
	    {"LATIN8",        "ISO-8859-8"  },
	    {"LATIN9",        "ISO-8859-9"  },
	    {"LATIN10",       "ISO-8859-10" },
	    {"MULE_INTERNAL", "Emacs-Mule"  },
	    {"SJIS",          "Windows-31J" },
	    {"SHIFT_JIS_2004","Windows-31J" },
	    /* {"SQL_ASCII",     NULL          },  special case*/
	    {"UHC",           "CP949"       },
	    {"UTF8",          "UTF-8"       },
	    {"WIN866",        "IBM866"      },
	    {"WIN874",        "Windows-874" },
	    {"WIN1250",       "Windows-1250"},
	    {"WIN1251",       "Windows-1251"},
	    {"WIN1252",       "Windows-1252"},
	    {"WIN1253",       "Windows-1253"},
	    {"WIN1254",       "Windows-1254"},
	    {"WIN1255",       "Windows-1255"},
	    {"WIN1256",       "Windows-1256"},
	    {"WIN1257",       "Windows-1257"},
	    {"WIN1258",       "Windows-1258"}
};


/*
 * A cache of mapping from PostgreSQL's encoding indices to Ruby's rb_encoding*s.
 */
static struct st_table *enc_pg2ruby;
static ID s_id_index;

static int enc_get_index(VALUE val)
{
	int i = ENCODING_GET_INLINED(val);
	if (i == ENCODING_INLINE_MAX) {
		VALUE iv = rb_ivar_get(val, s_id_index);
		i = NUM2INT(iv);
	}
	return i;
}

extern int rb_enc_alias(const char *alias, const char *orig); /* declaration missing in Ruby 1.9.1 */
static rb_encoding *
find_or_create_johab(void)
{
	static const char * const aliases[] = { "JOHAB", "Windows-1361", "CP1361" };
	int enc_index;
	int i;
	for (i = 0; i < sizeof(aliases)/sizeof(aliases[0]); ++i) {
		enc_index = rb_enc_find_index(aliases[i]);
		if (enc_index > 0) return rb_enc_from_index(enc_index);
	}

	enc_index = rb_define_dummy_encoding(aliases[0]);
	for (i = 1; i < sizeof(aliases)/sizeof(aliases[0]); ++i) {
		rb_enc_alias(aliases[i], aliases[0]);
	}
	return rb_enc_from_index(enc_index);
}

/*
 * Returns the client_encoding of the given connection as a rb_encoding*
 *
 * * returns NULL if the client encoding is 'SQL_ASCII'.
 * * returns ASCII-8BIT if the client encoding is unknown.
 */
static rb_encoding *
pgconn_get_client_encoding_as_rb_encoding(PGconn* conn)
{
	rb_encoding *enc;
	int enc_id = PQclientEncoding(conn);

	if (st_lookup(enc_pg2ruby, (st_data_t)enc_id, (st_data_t*)&enc)) {
		return enc;
	}
	else {
		int i;
		const char *name = pg_encoding_to_char(enc_id);
		if (strcmp("SQL_ASCII", name) == 0) {
			enc = NULL;
			goto cache;
		}
		for (i = 0; i < sizeof(enc_pg2ruby_mapping)/sizeof(enc_pg2ruby_mapping[0]); ++i) {
			if (strcmp(name, enc_pg2ruby_mapping[i][0]) == 0) {
				enc = rb_enc_find(enc_pg2ruby_mapping[i][1]);
				goto cache;
			}
		}

		/* Ruby 1.9.1 does not supoort JOHAB */
		if (strcmp(name, "JOHAB") == 0) {
			enc = find_or_create_johab();
			goto cache;
		}

		enc = rb_ascii8bit_encoding();
	}
cache:
	st_insert(enc_pg2ruby, (st_data_t)enc_id, (st_data_t)enc);
	return enc;
}


/* 
 * Returns the given rb_encoding as the equivalent PostgreSQL encoding string.
 * 
 */
static const char *
pgconn_get_rb_encoding_as_pg_encname( rb_encoding *enc )
{
	const char *rb_encname = rb_enc_name( enc );
	const char *encname = NULL;
	int i;

	for (i = 0; i < sizeof(enc_pg2ruby_mapping)/sizeof(enc_pg2ruby_mapping[0]); ++i) {
		if (strcmp(rb_encname, enc_pg2ruby_mapping[i][1]) == 0) {
			encname = enc_pg2ruby_mapping[i][0];
		}
	}

	if ( !encname ) encname = "SQL_ASCII";

	return encname;
}


/*
 * call-seq:
 *   conn.internal_encoding() -> Encoding
 *
 * defined in Ruby 1.9 or later.
 *
 * Returns:
 * * an Encoding - client_encoding of the connection as a Ruby Encoding object.
 * * nil - the client_encoding is 'SQL_ASCII'
 */
static VALUE
pgconn_internal_encoding(VALUE self)
{
	return rb_enc_from_encoding(pgconn_get_client_encoding_as_rb_encoding(get_pgconn(self)));
}

static VALUE pgconn_external_encoding(VALUE self);

/*
 * call-seq:
 *   conn.internal_encoding = value
 *
 * A wrapper of +PGconn#set_client_encoding+.
 * defined in Ruby 1.9 or later.
 *
 * +value+ can be one of:
 * * an Encoding
 * * a String - a name of Encoding
 * * +nil+ - sets 'SQL_ASCII' to the client_encoding.
 */
static VALUE
pgconn_internal_encoding_set(VALUE self, VALUE enc)
{
	if (NIL_P(enc)) {
		pgconn_set_client_encoding(self, rb_usascii_str_new_cstr("SQL_ASCII"));
		return enc;
	}
	else if (TYPE(enc) == T_STRING && strcasecmp("JOHAB", RSTRING_PTR(enc)) == 0) {
		pgconn_set_client_encoding(self, rb_usascii_str_new_cstr("JOHAB"));
		return enc;
	}
	else {
		int i;
		const char *name; 
		name = rb_enc_name(rb_to_encoding(enc));

		/* sequential search becuase rarely called */
		for (i = 0; i < sizeof(enc_pg2ruby_mapping)/sizeof(enc_pg2ruby_mapping[0]); ++i) {
			if (strcmp(name, enc_pg2ruby_mapping[i][1]) == 0) {
				if (PQsetClientEncoding(get_pgconn(self), enc_pg2ruby_mapping[i][0]) == -1) {
					VALUE server_encoding = pgconn_external_encoding(self);
					rb_raise(rb_eEncCompatError, "imcompatible character encodings: %s and %s",
							rb_enc_name(rb_to_encoding(server_encoding)),
							enc_pg2ruby_mapping[i][0]);
				}
				return enc;
			}
		}

		/* Ruby 1.9.1 does not support JOHAB */
		if (strcasecmp(name, "JOHAB") == 0) {
			pgconn_set_client_encoding(self, rb_usascii_str_new_cstr("JOHAB"));
			return enc;
		}
	}

	enc = rb_inspect(enc);
	rb_raise(rb_ePGError, "unknown encoding: %s", StringValuePtr(enc));
}



static VALUE enc_server_encoding_getvalue(VALUE pgresult)
{
	return pgresult_getvalue(pgresult, INT2FIX(0), INT2FIX(0));
}

/*
 * call-seq:
 *   conn.external_encoding() -> Encoding
 *
 * defined in Ruby 1.9 or later.
 * * Returns the server_encoding of the connected database as a Ruby Encoding object.
 * * Maps 'SQL_ASCII' to ASCII-8BIT.
 */
static VALUE
pgconn_external_encoding(VALUE self)
{
	VALUE enc;
	enc = rb_iv_get(self, "@external_encoding");
	if (RTEST(enc)) {
		return enc;
	}
	else {
		int i;
		VALUE query = rb_usascii_str_new_cstr("SHOW server_encoding");
		VALUE pgresult = pgconn_exec(1, &query, self);
		VALUE enc_name = rb_ensure(enc_server_encoding_getvalue, pgresult, pgresult_clear, pgresult);

		if (strcmp("SQL_ASCII", StringValuePtr(enc_name)) == 0) {
			enc = rb_enc_from_encoding(rb_ascii8bit_encoding());
			goto cache;
		}
		for (i = 0; i < sizeof(enc_pg2ruby_mapping)/sizeof(enc_pg2ruby_mapping[0]); ++i) {
			if (strcmp(StringValuePtr(enc_name), enc_pg2ruby_mapping[i][0]) == 0) {
				enc = rb_enc_from_encoding(rb_enc_find(enc_pg2ruby_mapping[i][1]));
				goto cache;
			}
		}

		/* Ruby 1.9.1 does not supoort JOHAB */
		if (strcmp(StringValuePtr(enc_name), "JOHAB") == 0) {
			enc = rb_enc_from_encoding(find_or_create_johab());
			goto cache;
		}

		/* fallback */
		enc = rb_enc_from_encoding(rb_enc_find(StringValuePtr(enc_name)));
	}

cache:
	rb_iv_set(self, "@external_encoding", enc);
	return enc;
}

static void
init_m17n(void)
{
	enc_pg2ruby = st_init_numtable();
	s_id_index = rb_intern("@encoding");
	rb_define_method(rb_cPGconn, "internal_encoding", pgconn_internal_encoding, 0);
	rb_define_method(rb_cPGconn, "internal_encoding=", pgconn_internal_encoding_set, 1);
	rb_define_method(rb_cPGconn, "external_encoding", pgconn_external_encoding, 0);
}


#endif
/**************************************************************************/

void
Init_pg_ext()
{
	rb_ePGError = rb_define_class("PGError", rb_eStandardError);
	rb_cPGconn = rb_define_class("PGconn", rb_cObject);
	rb_cPGresult = rb_define_class("PGresult", rb_cObject);

	/* Library version */
	rb_define_const( rb_cPGconn, "VERSION", rb_str_new2(VERSION) );

	/*************************
	 *  PGError 
	 *************************/
	rb_define_alias(rb_ePGError, "error", "message");
	rb_define_attr(rb_ePGError, "connection", 1, 0);
	rb_define_attr(rb_ePGError, "result", 1, 0);

	/*************************
	 *  PGconn 
	 *************************/

	/******     PGconn CLASS METHODS     ******/
	rb_define_alloc_func(rb_cPGconn, pgconn_alloc);
	rb_define_singleton_alias(rb_cPGconn, "connect", "new");
	rb_define_singleton_alias(rb_cPGconn, "open", "new");
	rb_define_singleton_alias(rb_cPGconn, "setdb", "new");
	rb_define_singleton_alias(rb_cPGconn, "setdblogin", "new");
	rb_define_singleton_method(rb_cPGconn, "escape_string", pgconn_s_escape, 1);
	rb_define_singleton_alias(rb_cPGconn, "escape", "escape_string");
	rb_define_singleton_method(rb_cPGconn, "escape_bytea", pgconn_s_escape_bytea, 1);
	rb_define_singleton_method(rb_cPGconn, "unescape_bytea", pgconn_s_unescape_bytea, 1);
	rb_define_singleton_method(rb_cPGconn, "isthreadsafe", pgconn_s_isthreadsafe, 0);
	rb_define_singleton_method(rb_cPGconn, "encrypt_password", pgconn_s_encrypt_password, 2);
	rb_define_singleton_method(rb_cPGconn, "quote_ident", pgconn_s_quote_ident, 1);
	rb_define_singleton_method(rb_cPGconn, "connect_start", pgconn_s_connect_start, -1);
	rb_define_singleton_method(rb_cPGconn, "conndefaults", pgconn_s_conndefaults, 0);
	

	/******     PGconn CLASS CONSTANTS: Connection Status     ******/

	/* Connection succeeded */
	rb_define_const(rb_cPGconn, "CONNECTION_OK", INT2FIX(CONNECTION_OK));
	/* Connection failed */
	rb_define_const(rb_cPGconn, "CONNECTION_BAD", INT2FIX(CONNECTION_BAD));

	/******     PGconn CLASS CONSTANTS: Nonblocking connection status     ******/

	/* Waiting for connection to be made. */
	rb_define_const(rb_cPGconn, "CONNECTION_STARTED", INT2FIX(CONNECTION_STARTED));
	/* Connection OK; waiting to send. */
	rb_define_const(rb_cPGconn, "CONNECTION_MADE", INT2FIX(CONNECTION_MADE));
	/* Waiting for a response from the server. */
	rb_define_const(rb_cPGconn, "CONNECTION_AWAITING_RESPONSE", INT2FIX(CONNECTION_AWAITING_RESPONSE));
	/* Received authentication; waiting for backend start-up to ﬁnish. */
	rb_define_const(rb_cPGconn, "CONNECTION_AUTH_OK", INT2FIX(CONNECTION_AUTH_OK));
	/* Negotiating SSL encryption. */
	rb_define_const(rb_cPGconn, "CONNECTION_SSL_STARTUP", INT2FIX(CONNECTION_SSL_STARTUP));
	/* Negotiating environment-driven parameter settings. */
	rb_define_const(rb_cPGconn, "CONNECTION_SETENV", INT2FIX(CONNECTION_SETENV));

	/******     PGconn CLASS CONSTANTS: Nonblocking connection polling status     ******/

	/* Async connection is waiting to read */
	rb_define_const(rb_cPGconn, "PGRES_POLLING_READING", INT2FIX(PGRES_POLLING_READING));
	/* Async connection is waiting to write */
	rb_define_const(rb_cPGconn, "PGRES_POLLING_WRITING", INT2FIX(PGRES_POLLING_WRITING));
	/* Async connection failed or was reset */
	rb_define_const(rb_cPGconn, "PGRES_POLLING_FAILED", INT2FIX(PGRES_POLLING_FAILED));
	/* Async connection succeeded */
	rb_define_const(rb_cPGconn, "PGRES_POLLING_OK", INT2FIX(PGRES_POLLING_OK));

	/******     PGconn CLASS CONSTANTS: Transaction Status     ******/

	/* Transaction is currently idle (#transaction_status) */
	rb_define_const(rb_cPGconn, "PQTRANS_IDLE", INT2FIX(PQTRANS_IDLE));
	/* Transaction is currently active; query has been sent to the server, but not yet completed. (#transaction_status) */
	rb_define_const(rb_cPGconn, "PQTRANS_ACTIVE", INT2FIX(PQTRANS_ACTIVE));
	/* Transaction is currently idle, in a valid transaction block (#transaction_status) */
	rb_define_const(rb_cPGconn, "PQTRANS_INTRANS", INT2FIX(PQTRANS_INTRANS));
	/* Transaction is currently idle, in a failed transaction block (#transaction_status) */
	rb_define_const(rb_cPGconn, "PQTRANS_INERROR", INT2FIX(PQTRANS_INERROR));
	/* Transaction's connection is bad (#transaction_status) */
	rb_define_const(rb_cPGconn, "PQTRANS_UNKNOWN", INT2FIX(PQTRANS_UNKNOWN));

	/******     PGconn CLASS CONSTANTS: Error Verbosity     ******/

	/* Terse error verbosity level (#set_error_verbosity) */
	rb_define_const(rb_cPGconn, "PQERRORS_TERSE", INT2FIX(PQERRORS_TERSE));
	/* Default error verbosity level (#set_error_verbosity) */
	rb_define_const(rb_cPGconn, "PQERRORS_DEFAULT", INT2FIX(PQERRORS_DEFAULT));
	/* Verbose error verbosity level (#set_error_verbosity) */
	rb_define_const(rb_cPGconn, "PQERRORS_VERBOSE", INT2FIX(PQERRORS_VERBOSE));

	/******     PGconn CLASS CONSTANTS: Large Objects     ******/

	/* Flag for #lo_creat, #lo_open -- open for writing */
	rb_define_const(rb_cPGconn, "INV_WRITE", INT2FIX(INV_WRITE));
	/* Flag for #lo_creat, #lo_open -- open for reading */
	rb_define_const(rb_cPGconn, "INV_READ", INT2FIX(INV_READ));
	/* Flag for #lo_lseek -- seek from object start */
	rb_define_const(rb_cPGconn, "SEEK_SET", INT2FIX(SEEK_SET));
	/* Flag for #lo_lseek -- seek from current position */
	rb_define_const(rb_cPGconn, "SEEK_CUR", INT2FIX(SEEK_CUR));
	/* Flag for #lo_lseek -- seek from object end */
	rb_define_const(rb_cPGconn, "SEEK_END", INT2FIX(SEEK_END));

	/******     PGconn INSTANCE METHODS: Connection Control     ******/
	rb_define_method(rb_cPGconn, "initialize", pgconn_init, -1);
	rb_define_method(rb_cPGconn, "connect_poll", pgconn_connect_poll, 0);
	rb_define_method(rb_cPGconn, "finish", pgconn_finish, 0);
	rb_define_method(rb_cPGconn, "reset", pgconn_reset, 0);
	rb_define_method(rb_cPGconn, "reset_start", pgconn_reset_start, 0);
	rb_define_method(rb_cPGconn, "reset_poll", pgconn_reset_poll, 0);
	rb_define_method(rb_cPGconn, "conndefaults", pgconn_s_conndefaults, 0);
	rb_define_alias(rb_cPGconn, "close", "finish");

	/******     PGconn INSTANCE METHODS: Connection Status     ******/
	rb_define_method(rb_cPGconn, "db", pgconn_db, 0);
	rb_define_method(rb_cPGconn, "user", pgconn_user, 0);
	rb_define_method(rb_cPGconn, "pass", pgconn_pass, 0);
	rb_define_method(rb_cPGconn, "host", pgconn_host, 0);
	rb_define_method(rb_cPGconn, "port", pgconn_port, 0);
	rb_define_method(rb_cPGconn, "tty", pgconn_tty, 0);
	rb_define_method(rb_cPGconn, "options", pgconn_options, 0);
	rb_define_method(rb_cPGconn, "status", pgconn_status, 0);
	rb_define_method(rb_cPGconn, "transaction_status", pgconn_transaction_status, 0);
	rb_define_method(rb_cPGconn, "parameter_status", pgconn_parameter_status, 1);
	rb_define_method(rb_cPGconn, "protocol_version", pgconn_protocol_version, 0);
	rb_define_method(rb_cPGconn, "server_version", pgconn_server_version, 0);
	rb_define_method(rb_cPGconn, "error_message", pgconn_error_message, 0);
	rb_define_method(rb_cPGconn, "socket", pgconn_socket, 0);
	rb_define_method(rb_cPGconn, "backend_pid", pgconn_backend_pid, 0);
	rb_define_method(rb_cPGconn, "connection_needs_password", pgconn_connection_needs_password, 0);
	rb_define_method(rb_cPGconn, "connection_used_password", pgconn_connection_used_password, 0);
	//rb_define_method(rb_cPGconn, "getssl", pgconn_getssl, 0);

	/******     PGconn INSTANCE METHODS: Command Execution     ******/
	rb_define_method(rb_cPGconn, "exec", pgconn_exec, -1);
	rb_define_alias(rb_cPGconn, "query", "exec");
	rb_define_method(rb_cPGconn, "prepare", pgconn_prepare, -1);
	rb_define_method(rb_cPGconn, "exec_prepared", pgconn_exec_prepared, -1);
	rb_define_method(rb_cPGconn, "describe_prepared", pgconn_describe_prepared, 1);
	rb_define_method(rb_cPGconn, "describe_portal", pgconn_describe_portal, 1);
	rb_define_method(rb_cPGconn, "make_empty_pgresult", pgconn_make_empty_pgresult, 1);
	rb_define_method(rb_cPGconn, "escape_string", pgconn_s_escape, 1);
	rb_define_alias(rb_cPGconn, "escape", "escape_string");
	rb_define_method(rb_cPGconn, "escape_bytea", pgconn_s_escape_bytea, 1);
	rb_define_method(rb_cPGconn, "unescape_bytea", pgconn_s_unescape_bytea, 1);

	/******     PGconn INSTANCE METHODS: Asynchronous Command Processing     ******/
	rb_define_method(rb_cPGconn, "send_query", pgconn_send_query, -1);
	rb_define_method(rb_cPGconn, "send_prepare", pgconn_send_prepare, -1);
	rb_define_method(rb_cPGconn, "send_query_prepared", pgconn_send_query_prepared, -1);
	rb_define_method(rb_cPGconn, "send_describe_prepared", pgconn_send_describe_prepared, 1);
	rb_define_method(rb_cPGconn, "send_describe_portal", pgconn_send_describe_portal, 1);
	rb_define_method(rb_cPGconn, "get_result", pgconn_get_result, 0);
	rb_define_method(rb_cPGconn, "consume_input", pgconn_consume_input, 0);
	rb_define_method(rb_cPGconn, "is_busy", pgconn_is_busy, 0);
	rb_define_method(rb_cPGconn, "setnonblocking", pgconn_setnonblocking, 1);
	rb_define_method(rb_cPGconn, "isnonblocking", pgconn_isnonblocking, 0);
	rb_define_alias(rb_cPGconn, "nonblocking?", "isnonblocking");
	rb_define_method(rb_cPGconn, "flush", pgconn_flush, 0);

	/******     PGconn INSTANCE METHODS: Cancelling Queries in Progress     ******/
	rb_define_method(rb_cPGconn, "cancel", pgconn_cancel, 0);

	/******     PGconn INSTANCE METHODS: NOTIFY     ******/
	rb_define_method(rb_cPGconn, "notifies", pgconn_notifies, 0);

	/******     PGconn INSTANCE METHODS: COPY     ******/
	rb_define_method(rb_cPGconn, "put_copy_data", pgconn_put_copy_data, 1);
	rb_define_method(rb_cPGconn, "put_copy_end", pgconn_put_copy_end, -1);
	rb_define_method(rb_cPGconn, "get_copy_data", pgconn_get_copy_data, -1);

	/******     PGconn INSTANCE METHODS: Control Functions     ******/
	rb_define_method(rb_cPGconn, "set_error_verbosity", pgconn_set_error_verbosity, 1);
	rb_define_method(rb_cPGconn, "trace", pgconn_trace, 1);
	rb_define_method(rb_cPGconn, "untrace", pgconn_untrace, 0);

	/******     PGconn INSTANCE METHODS: Notice Processing     ******/
	rb_define_method(rb_cPGconn, "set_notice_receiver", pgconn_set_notice_receiver, 0);
	rb_define_method(rb_cPGconn, "set_notice_processor", pgconn_set_notice_processor, 0);

	/******     PGconn INSTANCE METHODS: Other    ******/
	rb_define_method(rb_cPGconn, "get_client_encoding", pgconn_get_client_encoding, 0);
	rb_define_method(rb_cPGconn, "set_client_encoding", pgconn_set_client_encoding, 1);
	rb_define_method(rb_cPGconn, "transaction", pgconn_transaction, 0);
	rb_define_method(rb_cPGconn, "block", pgconn_block, -1);
	rb_define_method(rb_cPGconn, "wait_for_notify", pgconn_wait_for_notify, -1);
	rb_define_alias(rb_cPGconn, "notifies_wait", "wait_for_notify");
	rb_define_method(rb_cPGconn, "quote_ident", pgconn_s_quote_ident, 1);
	rb_define_method(rb_cPGconn, "async_exec", pgconn_async_exec, -1);
	rb_define_alias(rb_cPGconn, "async_query", "async_exec");
	rb_define_method(rb_cPGconn, "get_last_result", pgconn_get_last_result, 0);

	/******     PGconn INSTANCE METHODS: Large Object Support     ******/
	rb_define_method(rb_cPGconn, "lo_creat", pgconn_locreat, -1);
	rb_define_alias(rb_cPGconn, "locreat", "lo_creat");
	rb_define_method(rb_cPGconn, "lo_create", pgconn_locreate, 1);
	rb_define_alias(rb_cPGconn, "locreate", "lo_create");
	rb_define_method(rb_cPGconn, "lo_import", pgconn_loimport, 1);
	rb_define_alias(rb_cPGconn, "loimport", "lo_import");
	rb_define_method(rb_cPGconn, "lo_export", pgconn_loexport, 2);
	rb_define_alias(rb_cPGconn, "loexport", "lo_export");
	rb_define_method(rb_cPGconn, "lo_open", pgconn_loopen, -1);
	rb_define_alias(rb_cPGconn, "loopen", "lo_open");
	rb_define_method(rb_cPGconn, "lo_write",pgconn_lowrite, 2);
	rb_define_alias(rb_cPGconn, "lowrite", "lo_write");
	rb_define_method(rb_cPGconn, "lo_read",pgconn_loread, 2);
	rb_define_alias(rb_cPGconn, "loread", "lo_read");
	rb_define_method(rb_cPGconn, "lo_lseek",pgconn_lolseek, 3);
	rb_define_alias(rb_cPGconn, "lolseek", "lo_lseek");
	rb_define_alias(rb_cPGconn, "lo_seek", "lo_lseek");
	rb_define_alias(rb_cPGconn, "loseek", "lo_lseek");
	rb_define_method(rb_cPGconn, "lo_tell",pgconn_lotell, 1);
	rb_define_alias(rb_cPGconn, "lotell", "lo_tell");
	rb_define_method(rb_cPGconn, "lo_truncate", pgconn_lotruncate, 2);
	rb_define_alias(rb_cPGconn, "lotruncate", "lo_truncate");
	rb_define_method(rb_cPGconn, "lo_close",pgconn_loclose, 1);
	rb_define_alias(rb_cPGconn, "loclose", "lo_close");
	rb_define_method(rb_cPGconn, "lo_unlink", pgconn_lounlink, 1);
	rb_define_alias(rb_cPGconn, "lounlink", "lo_unlink");

	/*************************
	 *  PGresult 
	 *************************/
	rb_include_module(rb_cPGresult, rb_mEnumerable);

	/******     PGresult CONSTANTS: result status      ******/

	/* #result_status constant: The string sent to the server was empty. */
	rb_define_const(rb_cPGresult, "PGRES_EMPTY_QUERY", INT2FIX(PGRES_EMPTY_QUERY));
	/* #result_status constant: Successful completion of a command returning no data. */
	rb_define_const(rb_cPGresult, "PGRES_COMMAND_OK", INT2FIX(PGRES_COMMAND_OK));
 	/* #result_status constant: Successful completion of a command returning data 
	   (such as a SELECT or SHOW). */
	rb_define_const(rb_cPGresult, "PGRES_TUPLES_OK", INT2FIX(PGRES_TUPLES_OK));
	/* #result_status constant: Copy Out (from server) data transfer started. */
	rb_define_const(rb_cPGresult, "PGRES_COPY_OUT", INT2FIX(PGRES_COPY_OUT));
	/* #result_status constant: Copy In (to server) data transfer started. */
	rb_define_const(rb_cPGresult, "PGRES_COPY_IN", INT2FIX(PGRES_COPY_IN));
	/* #result_status constant: The server’s response was not understood. */
	rb_define_const(rb_cPGresult, "PGRES_BAD_RESPONSE", INT2FIX(PGRES_BAD_RESPONSE));
	/* #result_status constant: A nonfatal error (a notice or warning) occurred. */
	rb_define_const(rb_cPGresult, "PGRES_NONFATAL_ERROR",INT2FIX(PGRES_NONFATAL_ERROR));
	/* #result_status constant: A fatal error occurred. */
	rb_define_const(rb_cPGresult, "PGRES_FATAL_ERROR", INT2FIX(PGRES_FATAL_ERROR));

	/******     PGresult CONSTANTS: result error field codes      ******/

	/* #result_error_field argument constant: The severity; the field contents
	 * are ERROR, FATAL, or PANIC (in an error message), or WARNING, NOTICE,
	 * DEBUG, INFO, or LOG (in a notice message), or a localized translation
	 * of one of these. Always present.
	 */
	rb_define_const(rb_cPGresult, "PG_DIAG_SEVERITY", INT2FIX(PG_DIAG_SEVERITY));
	/* #result_error_field argument constant: The SQLSTATE code for the
	 * error. The SQLSTATE code identies the type of error that has occurred;
	 * it can be used by front-end applications to perform specic operations
	 * (such as er- ror handling) in response to a particular database
	 * error. For a list of the possible SQLSTATE codes, see Appendix A.
	 * This eld is not localizable, and is always present.
	 */
	rb_define_const(rb_cPGresult, "PG_DIAG_SQLSTATE", INT2FIX(PG_DIAG_SQLSTATE));
	/* #result_error_field argument constant: The primary human-readable
	 * error message (typically one line). Always present. */
	rb_define_const(rb_cPGresult, "PG_DIAG_MESSAGE_PRIMARY", INT2FIX(PG_DIAG_MESSAGE_PRIMARY));
	/* #result_error_field argument constant: Detail: an optional secondary
	 * error message carrying more detail about the problem. Might run to
	 * multiple lines.
	 */
	rb_define_const(rb_cPGresult, "PG_DIAG_MESSAGE_DETAIL", INT2FIX(PG_DIAG_MESSAGE_DETAIL));
	/* #result_error_field argument constant: Hint: an optional suggestion
	 * what to do about the problem. This is intended to differ from detail
	 * in that it offers advice (potentially inappropriate) rather than
	 * hard facts. Might run to multiple lines.
	 */
	rb_define_const(rb_cPGresult, "PG_DIAG_MESSAGE_HINT", INT2FIX(PG_DIAG_MESSAGE_HINT));
	/* #result_error_field argument constant: A string containing a decimal
	 * integer indicating an error cursor position as an index into the
	 * original statement string. The rst character has index 1, and
	 * positions are measured in characters not bytes.
	 */
	rb_define_const(rb_cPGresult, "PG_DIAG_STATEMENT_POSITION", INT2FIX(PG_DIAG_STATEMENT_POSITION));
	/* #result_error_field argument constant: This is dened the same as
	 * the PG_DIAG_STATEMENT_POSITION eld, but it is used when the cursor
	 * position refers to an internally generated command rather than the
	 * one submitted by the client. The PG_DIAG_INTERNAL_QUERY eld will
	 * always appear when this eld appears.
	 */
	rb_define_const(rb_cPGresult, "PG_DIAG_INTERNAL_POSITION", INT2FIX(PG_DIAG_INTERNAL_POSITION));
	/* #result_error_field argument constant: The text of a failed
	 * internally-generated command. This could be, for example, a SQL
	 * query issued by a PL/pgSQL function.
	 */
	rb_define_const(rb_cPGresult, "PG_DIAG_INTERNAL_QUERY", INT2FIX(PG_DIAG_INTERNAL_QUERY));
	/* #result_error_field argument constant: An indication of the context
	 * in which the error occurred. Presently this includes a call stack
	 * traceback of active procedural language functions and internally-generated
	 * queries. The trace is one entry per line, most recent rst.
	 */
	rb_define_const(rb_cPGresult, "PG_DIAG_CONTEXT", INT2FIX(PG_DIAG_CONTEXT));
	/* #result_error_field argument constant: The le name of the source-code
	 * location where the error was reported. */
	rb_define_const(rb_cPGresult, "PG_DIAG_SOURCE_FILE", INT2FIX(PG_DIAG_SOURCE_FILE));
	/* #result_error_field argument constant: The line number of the
	 * source-code location where the error was reported. */
	rb_define_const(rb_cPGresult, "PG_DIAG_SOURCE_LINE", INT2FIX(PG_DIAG_SOURCE_LINE));
	/* #result_error_field argument constant: The name of the source-code
	 * function reporting the error. */
	rb_define_const(rb_cPGresult, "PG_DIAG_SOURCE_FUNCTION", INT2FIX(PG_DIAG_SOURCE_FUNCTION));

	/* Invalid OID constant */
	rb_define_const(rb_cPGresult, "InvalidOid", INT2FIX(InvalidOid));

	/******     PGresult INSTANCE METHODS: libpq     ******/
	rb_define_method(rb_cPGresult, "result_status", pgresult_result_status, 0);
	rb_define_method(rb_cPGresult, "res_status", pgresult_res_status, 1);
	rb_define_method(rb_cPGresult, "result_error_message", pgresult_result_error_message, 0);
	rb_define_method(rb_cPGresult, "result_error_field", pgresult_result_error_field, 1);
	rb_define_method(rb_cPGresult, "clear", pgresult_clear, 0);
	rb_define_method(rb_cPGresult, "ntuples", pgresult_ntuples, 0);
	rb_define_alias(rb_cPGresult, "num_tuples", "ntuples");
	rb_define_method(rb_cPGresult, "nfields", pgresult_nfields, 0);
	rb_define_alias(rb_cPGresult, "num_fields", "nfields");
	rb_define_method(rb_cPGresult, "fname", pgresult_fname, 1);
	rb_define_method(rb_cPGresult, "fnumber", pgresult_fnumber, 1);
	rb_define_method(rb_cPGresult, "ftable", pgresult_ftable, 1);
	rb_define_method(rb_cPGresult, "ftablecol", pgresult_ftablecol, 1);
	rb_define_method(rb_cPGresult, "fformat", pgresult_fformat, 1);
	rb_define_method(rb_cPGresult, "ftype", pgresult_ftype, 1);
	rb_define_method(rb_cPGresult, "fmod", pgresult_fmod, 1);
	rb_define_method(rb_cPGresult, "fsize", pgresult_fsize, 1);
	rb_define_method(rb_cPGresult, "getvalue", pgresult_getvalue, 2);
	rb_define_method(rb_cPGresult, "getisnull", pgresult_getisnull, 2);
	rb_define_method(rb_cPGresult, "getlength", pgresult_getlength, 2);
	rb_define_method(rb_cPGresult, "nparams", pgresult_nparams, 0);
	rb_define_method(rb_cPGresult, "paramtype", pgresult_paramtype, 1);
	rb_define_method(rb_cPGresult, "cmd_status", pgresult_cmd_status, 0);
	rb_define_method(rb_cPGresult, "cmd_tuples", pgresult_cmd_tuples, 0);
	rb_define_alias(rb_cPGresult, "cmdtuples", "cmd_tuples");
	rb_define_method(rb_cPGresult, "oid_value", pgresult_oid_value, 0);

	/******     PGresult INSTANCE METHODS: other     ******/
	rb_define_method(rb_cPGresult, "[]", pgresult_aref, 1);
	rb_define_method(rb_cPGresult, "each", pgresult_each, 0);
	rb_define_method(rb_cPGresult, "fields", pgresult_fields, 0);
	rb_define_method(rb_cPGresult, "values", pgresult_values, 0);
	rb_define_method(rb_cPGresult, "column_values", pgresult_column_values, 1);
	rb_define_method(rb_cPGresult, "field_values", pgresult_field_values, 1);

#ifdef M17N_SUPPORTED
	init_m17n();
#endif
}

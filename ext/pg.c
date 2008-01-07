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

#define AssignCheckedStringValue(cstring, rstring) do { \
    if (!NIL_P(temp = rstring)) { \
        Check_Type(temp, T_STRING); \
        cstring = StringValuePtr(temp); \
    } \
} while (0)

#define rb_define_singleton_alias(klass,new,old) rb_define_alias(rb_singleton_class(klass),new,old)

static VALUE rb_cPGconn;
static VALUE rb_cPGresult;
static VALUE rb_ePGError;

/* The following functions are part of libpq, but not
 * available from ruby-pg, because they are deprecated,
 * obsolete, or generally not useful.
 *
 * * PQfreemem -- unnecessary: copied to ruby object, then
 *                freed. Ruby object's memory is freed when
 *                it is garbage collected.
 * * PQbinaryTuples -- better to use PQfformat
 * * PQprint -- not very useful
 * * PQsetdb -- not very useful
 * * PQsetdbLogin -- not very useful
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

static void free_pgconn(PGconn *);
static void pgresult_check(VALUE, VALUE);

static PGconn *get_pgconn(VALUE self);
static VALUE pgconn_finish(VALUE self);
static VALUE pgresult_clear(VALUE self);
static VALUE pgresult_aref(VALUE self, VALUE index);

/*
 * Used to quote the values passed in a Hash to PGconn.init
 * when building the connection string.
 */
static VALUE
pgconn_s_quote_connstr(string)
    VALUE string;
{
	char *str,*ptr;
	int i,j=0,len;
	VALUE result;

	Check_Type(string, T_STRING);

	ptr = RSTRING_PTR(string);
	len = RSTRING_LEN(string);
	str = ALLOCA_N(char, len * 2 + 2 + 1);
	str[j++] = '\'';
	for(i = 0; i < len; i++) {
		if(ptr[i] == '\'' || ptr[i] == '\\')
			str[j++] = '\\';
		str[j++] = ptr[i];	
	}
	str[j++] = '\'';
	result = rb_str_new(str, j);
	return result;
}

/*
 * Appends key='hash[key]' to conninfo_rstr
 */
static void
build_key_value_string(hash, conninfo_rstr, key)
	VALUE hash, conninfo_rstr;
	char *key;
{
	if(rb_funcall(hash, rb_intern("has_key?"), 1, ID2SYM(rb_intern(key)))) {
		rb_str_cat2(conninfo_rstr, " ");
		rb_str_cat2(conninfo_rstr, key);
		rb_str_cat2(conninfo_rstr, "=");
		rb_str_concat(conninfo_rstr, pgconn_s_quote_connstr(rb_obj_as_string(
			rb_hash_aref(hash, ID2SYM(rb_intern(key))))));
	}
	return;
}

static void
free_pgconn(PGconn *conn)
{
    PQfinish(conn);
}

static void
free_pgresult(PGresult *result)
{
    PQclear(result);
}

static PGconn*
get_pgconn(VALUE self)
{
	PGconn *conn;
	Data_Get_Struct(self, PGconn, conn);
	if (conn == NULL) rb_raise(rb_eStandardError, "not connected");
	return conn;
}

static PGresult*
get_pgresult(VALUE self)
{
    PGresult *result;
    Data_Get_Struct(self, PGresult, result);
    if (result == NULL) rb_raise(rb_eStandardError, "result has been cleared");
    return result;
}

static VALUE
new_pgresult(PGresult *result)
{
    return Data_Wrap_Struct(rb_cPGresult, NULL, free_pgresult, result);
}

/*
 * Raises appropriate exception if PGresult is
 * in a bad state.
 */
static void
pgresult_check(VALUE rb_pgconn, VALUE rb_pgresult)
{
	VALUE error;
	PGconn *conn = get_pgconn(rb_pgconn);
	PGresult *result = get_pgresult(rb_pgresult);

	if(result == NULL)
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
	switch (PQresultStatus(result)) {
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
	
	rb_iv_set(error, "@connection", rb_pgconn);
	rb_iv_set(error, "@result", rb_pgresult);
	rb_exc_raise(error);
	return;
}

static VALUE yield_pgresult(VALUE rb_pgresult)
{
	int i;
	PGresult *result = get_pgresult(rb_pgresult);
	for(i = 0; i < PQntuples(result); i++) {
		return rb_yield(pgresult_aref(rb_pgresult, INT2NUM(i)));
	}
	return Qnil;
}

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
 *    res  = conn.exec('select * from a')
 *
 * See the PGresult class for information on working with the results of a query.
 *
 */

#ifdef HAVE_RB_DEFINE_ALLOC_FUNC
static VALUE
pgconn_alloc(klass)
    VALUE klass;
{
	return Data_Wrap_Struct(klass, NULL, free_pgconn, NULL);
}
#else
static VALUE
pgconn_s_new(argc, argv, klass)
    int argc;
    VALUE *argv;
    VALUE klass;
{
    VALUE self = rb_obj_alloc(klass);
    rb_obj_call_init(self, argc, argv);
    return self;
}
#endif

/**************************************************************************
 * PGconn SINGLETON METHODS
 **************************************************************************/

/*
 * Document-method: new
 *
 * call-seq:
 *     PGconn.open(connection_hash) -> PGconn
 *     PGconn.open(connection_string) -> PGconn
 *     PGconn.open(host, port, options, tty, dbname, login, password) ->  PGconn
 *
 * * +host+ - server hostname
 * * +hostaddr+ - server address (avoids hostname lookup, overrides +host+)
 * * +port+ - server port number
 * * +dbname+ - connecting database name
 * * +user+ - login user name
 * * +password+ - login password
 * * +connect_timeout+ - maximum time to wait for connection to succeed
 * * +options+ - backend options
 * * +tty+ - (ignored in newer versions of PostgreSQL)
 * * +sslmode+ - (disable|allow|prefer|require)
 * * +krbsrvname+ - kerberos service name
 * * +gsslib+ - GSS library to use for GSSAPI authentication
 * * +service+ - service name to use for additional parameters
 *
 * _connection_hash_ example: +PGconn.connect(:dbname=>'test', :port=>5432)
 * _connection_string_ example: +PGconn.connect("dbname=test port=5432")
 * _connection_hash_ example: +PGconn.connect(nil,5432,nil,nil,'test',nil,nil)
 *  
 *  On failure, it raises a PGError exception.
 */

static VALUE
pgconn_init(argc, argv, self)
    int argc;
    VALUE *argv;
    VALUE self;
{
    VALUE args,arg;
    PGconn *conn = NULL;
	char *conninfo = NULL;
	VALUE conninfo_rstr;
	VALUE error;
	VALUE temp;
	char *host, *port, *opt, *tty, *dbname, *login, *pwd;
	host=port=opt=tty=dbname=login=pwd=NULL;

    rb_scan_args(argc, argv, "0*", &args); 
    if (RARRAY_LEN(args) == 1) { 
		arg = rb_ary_entry(args,0);
		if(TYPE(arg) == T_HASH) {
			conninfo_rstr = rb_str_new2("");
			build_key_value_string(arg, conninfo_rstr, "host");
			build_key_value_string(arg, conninfo_rstr, "hostaddr");
			build_key_value_string(arg, conninfo_rstr, "port");
			build_key_value_string(arg, conninfo_rstr, "dbname");
			build_key_value_string(arg, conninfo_rstr, "user");
			build_key_value_string(arg, conninfo_rstr, "password");
			build_key_value_string(arg, conninfo_rstr, "opt");
			build_key_value_string(arg, conninfo_rstr, "tty");
			build_key_value_string(arg, conninfo_rstr, "sslmode");
			build_key_value_string(arg, conninfo_rstr, "krbsrvname");
			build_key_value_string(arg, conninfo_rstr, "gsslib");
			build_key_value_string(arg, conninfo_rstr, "service");
			conninfo = StringValuePtr(conninfo_rstr);
		}
		else if(TYPE(arg) == T_STRING) {
			conninfo = StringValuePtr(arg);
		}
		else {
			rb_raise(rb_eArgError, 
				"Expecting String or Hash as single argument");
		}
		conn = PQconnectdb(conninfo);
    }
	else if (RARRAY_LEN(args) == 7) {
		AssignCheckedStringValue(host, rb_ary_entry(args, 0));
		AssignCheckedStringValue(port, rb_obj_as_string(rb_ary_entry(args, 1)));
		AssignCheckedStringValue(opt, rb_ary_entry(args, 2));
		AssignCheckedStringValue(tty, rb_ary_entry(args, 3));
		AssignCheckedStringValue(dbname, rb_ary_entry(args, 4));
		AssignCheckedStringValue(login, rb_ary_entry(args, 5));
		AssignCheckedStringValue(pwd, rb_ary_entry(args, 6));

		conn = PQsetdbLogin(host, port, opt, tty, dbname, login, pwd);
	}
	else {
		rb_raise(rb_eArgError, 
			"Expected connection info string, hash, or 7 separate arguments.");
	}

    if (PQstatus(conn) == CONNECTION_BAD) {
        error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
        rb_iv_set(error, "@connection", self);
        rb_exc_raise(error);
    }

	Check_Type(self, T_DATA);
	DATA_PTR(self) = conn;
	
    if (rb_block_given_p()) {
        return rb_ensure(rb_yield, self, pgconn_finish, self);
    }
    return self;
}

//TODO PGconn.conndefaults


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
pgconn_s_encrypt_password(self, password, username)
	VALUE self, password, username;
{
	char *ret;
	Check_Type(password, T_STRING);
	Check_Type(username, T_STRING);
	ret = PQencryptPassword(StringValuePtr(password),
		StringValuePtr(username));
	return rb_tainted_str_new2(ret);
}

/*
 * call-seq:
 *    PGconn.isthreadsafe() -> Boolean
 *
 * Returns +true+ if libpq is thread safe, +false+ otherwise.
 */
static VALUE
pgconn_s_isthreadsafe(self)
	VALUE self;
{
	return PQisthreadsafe() ? Qtrue : Qfalse;
}

/**************************************************************************
 * PGconn INSTANCE METHODS
 **************************************************************************/

/*
 * call-seq:
 *    conn.finish()
 *
 * Closes the backend connection.
 */
static VALUE
pgconn_finish(self)
    VALUE self;
{
    PQfinish(get_pgconn(self));
    DATA_PTR(self) = NULL;
    return Qnil;
}

/*
 * call-seq:
 *    conn.reset()
 *
 * Resets the backend connection. This method closes the backend connection and tries to re-connect.
 */
static VALUE
pgconn_reset(self)
    VALUE self;
{
    PQreset(get_pgconn(self));
    return self;
}

//TODO conn.reset_start

//TODO conn.reset_poll

/*
 * call-seq:
 *    conn.db()
 *
 * Returns the connected database name.
 */
static VALUE
pgconn_db(self)
    VALUE self;
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
pgconn_user(self)
    VALUE self;
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
pgconn_pass(self)
    VALUE self;
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
pgconn_host(self)
    VALUE self;
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
pgconn_port(self)
    VALUE self;
{
    char* port = PQport(get_pgconn(self));
    return INT2NUM(atol(port));
}

/*
 * call-seq:
 *    conn.tty()
 *
 * Returns the connected pgtty.
 */
static VALUE
pgconn_tty(self)
    VALUE self;
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
pgconn_options(self)
    VALUE self;
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
pgconn_status(self)
    VALUE self;
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
pgconn_transaction_status(self)
    VALUE self;
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
pgconn_parameter_status(self, param_name)
	VALUE self, param_name;
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
 *  conn.protocol_version -> Integer
 *
 * The 3.0 protocol will normally be used when communicating with PostgreSQL 7.4 
 * or later servers; pre-7.4 servers support only protocol 2.0. (Protocol 1.0 is 
 * obsolete and not supported by libpq.)
 */
static VALUE
pgconn_protocol_version(self)
    VALUE self;
{
    return INT2NUM(PQprotocolVersion(get_pgconn(self)));
}

/*
 * call-seq:
 *   conn.server_version -> Integer
 *
 * The number is formed by converting the major, minor, and revision numbers into two-decimal-digit numbers and appending them together. For example, version 7.4.2 will be returned as 70402, and version 8.1 will be returned as 80100 (leading zeroes are not shown). Zero is returned if the connection is bad.
 */
static VALUE
pgconn_server_version(self)
    VALUE self;
{
    return INT2NUM(PQserverVersion(get_pgconn(self)));
}

/*
 * call-seq:
 *    conn.error() -> String
 *
 * Returns the error message about connection.
 */
static VALUE
pgconn_error_message(self)
    VALUE self;
{
    char *error = PQerrorMessage(get_pgconn(self));
    if (!error) return Qnil;
    return rb_tainted_str_new2(error);
}

//TODO PQsocket
/*
 * call-seq:
 *    conn.socket() -> TCPSocket
 *
 * Returns the socket file descriptor of this
 * connection.
 */


/*
 * call-seq:
 *    conn.backed_pid() -> Fixnum
 *
 * Returns the process ID of the backend server
 * process for this connection.
 * Note that this is a PID on database server host.
 */
static VALUE
pgconn_backend_pid(self)
	VALUE self;
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
pgconn_connection_needs_password(self)
	VALUE self;
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
pgconn_connection_used_password(self)
	VALUE self;
{
	return PQconnectionUsedPassword(get_pgconn(self)) ? Qtrue : Qfalse;
}


//TODO get_ssl


/*
 * call-seq:
 *    conn.exec(sql) -> PGresult
 *
 * Sends SQL query request specified by _sql_ to the PostgreSQL.
 * Returns a PGresult instance on success.
 * On failure, it raises a PGError exception.
 *
 */
static VALUE
pgconn_exec(self, in_command)
    VALUE self, in_command;
{
    PGconn *conn = get_pgconn(self);
    PGresult *result = NULL;
	VALUE rb_pgresult;
	VALUE command;

	if(TYPE(in_command) == T_STRING)
		command = in_command;
	else
		command = rb_funcall(in_command, rb_intern("to_s"), 0);
	Check_Type(command, T_STRING);

	result = PQexec(conn, StringValuePtr(command));

	rb_pgresult = new_pgresult(result);
	pgresult_check(self, rb_pgresult);

    if (rb_block_given_p()) {
        return rb_ensure(yield_pgresult, rb_pgresult, 
			pgresult_clear, rb_pgresult);
    }
	return rb_pgresult;
}

/*
 * call-seq:
 *    conn.exec_params(sql, params, result_format) -> PGresult
 *
 * Sends SQL query request specified by _sql_ to PostgreSQL.
 * Returns a PGresult instance on success.
 * On failure, it raises a PGError exception.
 *
 * +params+ is an array of the bind parameters for the SQL query.
 * Each element of the +params+ array may be either:
 *   a hash of the form:
 *     {:value  => String (value of bind parameter)
 *      :type   => Fixnum (oid of type of bind parameter)
 *      :format => Fixnum (0 for text, 1 for binary)
 *     }
 *   or, it may be a String. If it is a string, that is equivalent to:
 *     { :value => <string value>, :type => 0, :format => 0 }
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query. The 0th element of the +params+ array is bound
 * to $1, the 1st element is bound to $2, etc.
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
pgconn_exec_params(argc, argv, self)
    int argc;
	VALUE *argv;
	VALUE self;
{
    PGconn *conn = get_pgconn(self);
    PGresult *result = NULL;
	VALUE rb_pgresult;
	VALUE command, params, in_res_fmt;
	VALUE param, param_type, param_value, param_format;
	VALUE param_value_tmp;
	VALUE sym_type, sym_value, sym_format;
	int i=0;
	int nParams;
	Oid *paramTypes;
	char ** paramValues;
	int *paramLengths;
	int *paramFormats;
	int resultFormat;

    rb_scan_args(argc, argv, "12", &command, &params, &in_res_fmt);

    Check_Type(command, T_STRING);
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

	sym_type = ID2SYM(rb_intern("type"));
	sym_value = ID2SYM(rb_intern("value"));
	sym_format = ID2SYM(rb_intern("format"));
	nParams = RARRAY(params)->len;
	paramTypes = ALLOC_N(Oid, nParams); 
	paramValues = ALLOC_N(char *, nParams);
	paramLengths = ALLOC_N(int, nParams);
	paramFormats = ALLOC_N(int, nParams);
	for(i = 0; i < nParams; i++) {
		param = rb_ary_entry(params, i);
		if (TYPE(param) == T_HASH) {
			param_type = rb_hash_aref(param, sym_type);
			param_value_tmp = rb_hash_aref(param, sym_value);
			if(TYPE(param_value_tmp) == T_STRING)
				param_value = param_value_tmp;
			else
				param_value = rb_funcall(param_value_tmp, rb_intern("to_s"), 0);
			param_format = rb_hash_aref(param, sym_format);
		}
		else {
			param_type = INT2NUM(0);
			if(TYPE(param) == T_STRING)
				param_value = param;
			else
				param_value = rb_funcall(param, rb_intern("to_s"), 0);
			param_format = INT2NUM(0);
		}
		Check_Type(param_value, T_STRING);
		paramTypes[i] = NUM2INT(param_type);
		paramValues[i] = RSTRING_PTR(param_value);
		paramLengths[i] = RSTRING_LEN(param_value) + 1;
		paramFormats[i] = NUM2INT(param_format);
	}
	
	result = PQexecParams(conn, StringValuePtr(command), nParams, paramTypes, 
		(const char * const *)paramValues, paramLengths, paramFormats, resultFormat);

	free(paramTypes);
	free(paramValues);
	free(paramLengths);
	free(paramFormats);

	rb_pgresult = new_pgresult(result);
	pgresult_check(self, rb_pgresult);
    if (rb_block_given_p()) {
        return rb_ensure(yield_pgresult, rb_pgresult, 
			pgresult_clear, rb_pgresult);
    }
	return rb_pgresult;
}

/*
 * call-seq:
 *    conn.prepare(sql, stmt_name, param_types) -> PGresult
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
pgconn_prepare(argc, argv, self)
    int argc;
	VALUE *argv;
	VALUE self;
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
		nParams = RARRAY(in_paramtypes)->len;
		paramTypes = ALLOC_N(Oid, nParams); 
		for(i = 0; i < nParams; i++) {
			param = rb_ary_entry(in_paramtypes, i);
			Check_Type(param, T_FIXNUM);
			paramTypes[i] = NUM2INT(param);
		}
	}
	result = PQprepare(conn, StringValuePtr(name), StringValuePtr(command),
			nParams, paramTypes);

	free(paramTypes);

	rb_pgresult = new_pgresult(result);
	pgresult_check(self, rb_pgresult);
	return rb_pgresult;
}

/*
 * call-seq:
 *    conn.exec_prepared(statement_name, params, result_format) -> PGresult
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
 *   or, it may be a String. If it is a string, that is equivalent to:
 *     { :value => <string value>, :format => 0 }
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query. The 0th element of the +params+ array is bound
 * to $1, the 1st element is bound to $2, etc.
 *
 * The optional +result_format+ should be 0 for text results, 1
 * for binary.
 */
static VALUE
pgconn_exec_prepared(argc, argv, self)
    int argc;
    VALUE *argv;
    VALUE self;
{
    PGconn *conn = get_pgconn(self);
    PGresult *result = NULL;
	VALUE rb_pgresult;
	VALUE name, params, in_res_fmt;
	VALUE param, param_value, param_format;
	VALUE param_value_tmp;
	VALUE sym_value, sym_format;
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

	sym_value = ID2SYM(rb_intern("value"));
	sym_format = ID2SYM(rb_intern("format"));
	nParams = RARRAY(params)->len;
	paramValues = ALLOC_N(char *, nParams);
	paramLengths = ALLOC_N(int, nParams);
	paramFormats = ALLOC_N(int, nParams);
	for(i = 0; i < nParams; i++) {
		param = rb_ary_entry(params, i);
		if (TYPE(param) == T_HASH) {
			param_value_tmp = rb_hash_aref(param, sym_value);
			if(TYPE(param_value_tmp) == T_STRING)
				param_value = param_value_tmp;
			else
				param_value = rb_funcall(param_value_tmp, rb_intern("to_s"), 0);
			param_format = rb_hash_aref(param, sym_format);
		}
		else {
			if(TYPE(param) == T_STRING)
				param_value = param;
			else
				param_value = rb_funcall(param, rb_intern("to_s"), 0);
			param_format = INT2NUM(0);
		}
		Check_Type(param_value, T_STRING);
		paramValues[i] = RSTRING_PTR(param_value);
		paramLengths[i] = RSTRING_LEN(param_value) + 1;
		paramFormats[i] = NUM2INT(param_format);
	}
	
	result = PQexecPrepared(conn, StringValuePtr(name), nParams, 
		(const char * const *)paramValues, paramLengths, paramFormats, 
		resultFormat);

	free(paramValues);
	free(paramLengths);
	free(paramFormats);

	rb_pgresult = new_pgresult(result);
	pgresult_check(self, rb_pgresult);
    if (rb_block_given_p()) {
        return rb_ensure(yield_pgresult, rb_pgresult, 
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
pgconn_describe_prepared(self, stmt_name)
	VALUE self, stmt_name;
{
	PGconn *conn = get_pgconn(self);
	PGresult *result;
	VALUE rb_pgresult;
	char *stmt;
	if(stmt_name == Qnil) {
		stmt = NULL;
	}
	else {
		Check_Type(stmt_name, T_STRING);
		stmt = StringValuePtr(stmt_name);
	}
	result = PQdescribePrepared(conn, stmt);
	rb_pgresult = new_pgresult(result);
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
	PGconn *conn = get_pgconn(self);
	PGresult *result;
	VALUE rb_pgresult;
	char *stmt;
	if(stmt_name == Qnil) {
		stmt = NULL;
	}
	else {
		Check_Type(stmt_name, T_STRING);
		stmt = StringValuePtr(stmt_name);
	}
	result = PQdescribePortal(conn, stmt);
	rb_pgresult = new_pgresult(result);
	pgresult_check(self, rb_pgresult);
	return rb_pgresult;
}


// TODO make_empty_pgresult


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
 */
static VALUE
pgconn_s_escape(self, string)
    VALUE self;
    VALUE string;
{
    char *escaped;
    int size,error;
    VALUE result;

    Check_Type(string, T_STRING);
    
    escaped = ALLOCA_N(char, RSTRING_LEN(string) * 2 + 1);
    if(CLASS_OF(self) == rb_cPGconn) {
    	size = PQescapeStringConn(get_pgconn(self), escaped, 
			RSTRING_PTR(string), RSTRING_LEN(string), &error);
		if(error) {
			rb_raise(rb_ePGError, PQerrorMessage(get_pgconn(self)));
		}
    } else {
    	size = PQescapeString(escaped, RSTRING_PTR(string),
			RSTRING_LEN(string));
    }
    result = rb_str_new(escaped, size);
    OBJ_INFECT(result, string);
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
pgconn_s_escape_bytea(self, str)
    VALUE self;
    VALUE str;
{
    unsigned char *from, *to;
    size_t from_len, to_len;
    VALUE ret;
    
    Check_Type(str, T_STRING);
    from      = (unsigned char*)RSTRING_PTR(str);
    from_len  = RSTRING_LEN(str);
    
    if(CLASS_OF(self) == rb_cPGconn) {
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
pgconn_s_unescape_bytea(self, str)
    VALUE self, str;
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
 *    conn.send_query( command ) -> nil
 *
 * Asynchronously send _command_ to the server. Does not block. 
 * Use in combination with +conn.get_result+.
 */
static VALUE
pgconn_send_query(self, command)
	VALUE self, command;
{
	VALUE error;
	PGconn *conn = get_pgconn(self);
	/* returns 0 on failure */
	if(PQsendQuery(conn,StringValuePtr(command)) == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}


/*
 * call-seq:
 *    conn.send_query_params(sql, params, result_format) -> nil
 *
 * Sends SQL query request specified by _sql_ to PostgreSQL for
 * asynchronous processing, and immediately returns.
 * On failure, it raises a PGError exception.
 *
 * +params+ is an array of the bind parameters for the SQL query.
 * Each element of the +params+ array may be either:
 *   a hash of the form:
 *     {:value  => String (value of bind parameter)
 *      :type   => Fixnum (oid of type of bind parameter)
 *      :format => Fixnum (0 for text, 1 for binary)
 *     }
 *   or, it may be a String. If it is a string, that is equivalent to:
 *     { :value => <string value>, :type => 0, :format => 0 }
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query. The 0th element of the +params+ array is bound
 * to $1, the 1st element is bound to $2, etc.
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
pgconn_send_query_params(argc, argv, self)
    int argc;
	VALUE *argv;
	VALUE self;
{
    PGconn *conn = get_pgconn(self);
    int result;
	VALUE command, params, in_res_fmt;
	VALUE param, param_type, param_value, param_format;
	VALUE param_value_tmp;
	VALUE sym_type, sym_value, sym_format;
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

	sym_type = ID2SYM(rb_intern("type"));
	sym_value = ID2SYM(rb_intern("value"));
	sym_format = ID2SYM(rb_intern("format"));
	nParams = RARRAY(params)->len;
	paramTypes = ALLOC_N(Oid, nParams); 
	paramValues = ALLOC_N(char *, nParams);
	paramLengths = ALLOC_N(int, nParams);
	paramFormats = ALLOC_N(int, nParams);
	for(i = 0; i < nParams; i++) {
		param = rb_ary_entry(params, i);
		if (TYPE(param) == T_HASH) {
			param_type = rb_hash_aref(param, sym_type);
			param_value_tmp = rb_hash_aref(param, sym_value);
			if(TYPE(param_value_tmp) == T_STRING)
				param_value = param_value_tmp;
			else
				param_value = rb_funcall(param_value_tmp, rb_intern("to_s"), 0);
			param_format = rb_hash_aref(param, sym_format);
		}
		else {
			param_type = INT2NUM(0);
			if(TYPE(param) == T_STRING)
				param_value = param;
			else
				param_value = rb_funcall(param, rb_intern("to_s"), 0);
			param_format = INT2NUM(0);
		}
		Check_Type(param_value, T_STRING);
		paramTypes[i] = NUM2INT(param_type);
		paramValues[i] = RSTRING_PTR(param_value);
		paramLengths[i] = RSTRING_LEN(param_value) + 1;
		paramFormats[i] = NUM2INT(param_format);
	}
	
	result = PQsendQueryParams(conn, StringValuePtr(command), nParams, paramTypes, 
		(const char * const *)paramValues, paramLengths, paramFormats, resultFormat);

	free(paramTypes);
	free(paramValues);
	free(paramLengths);
	free(paramFormats);

	if(result == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}

/*
 * call-seq:
 *    conn.send_prepare(sql, stmt_name, param_types) -> nil
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
pgconn_send_prepare(argc, argv, self)
    int argc;
	VALUE *argv;
	VALUE self;
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
		nParams = RARRAY(in_paramtypes)->len;
		paramTypes = ALLOC_N(Oid, nParams); 
		for(i = 0; i < nParams; i++) {
			param = rb_ary_entry(in_paramtypes, i);
			Check_Type(param, T_FIXNUM);
			paramTypes[i] = NUM2INT(param);
		}
	}
	result = PQsendPrepare(conn, StringValuePtr(name), StringValuePtr(command),
			nParams, paramTypes);

	free(paramTypes);

	if(result == 0) {
		error = rb_exc_new2(rb_ePGError, PQerrorMessage(conn));
		rb_iv_set(error, "@connection", self);
		rb_exc_raise(error);
	}
	return Qnil;
}

/*
 * call-seq:
 *    conn.send_query_prepared(statement_name, params, result_format) -> nil
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
 *   or, it may be a String. If it is a string, that is equivalent to:
 *     { :value => <string value>, :format => 0 }
 * 
 * PostgreSQL bind parameters are represented as $1, $1, $2, etc.,
 * inside the SQL query. The 0th element of the +params+ array is bound
 * to $1, the 1st element is bound to $2, etc.
 *
 * The optional +result_format+ should be 0 for text results, 1
 * for binary.
 */
static VALUE
pgconn_send_query_prepared(argc, argv, self)
    int argc;
    VALUE *argv;
    VALUE self;
{
    PGconn *conn = get_pgconn(self);
    int result;
	VALUE name, params, in_res_fmt;
	VALUE param, param_value, param_format;
	VALUE param_value_tmp;
	VALUE sym_value, sym_format;
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

	sym_value = ID2SYM(rb_intern("value"));
	sym_format = ID2SYM(rb_intern("format"));
	nParams = RARRAY(params)->len;
	paramValues = ALLOC_N(char *, nParams);
	paramLengths = ALLOC_N(int, nParams);
	paramFormats = ALLOC_N(int, nParams);
	for(i = 0; i < nParams; i++) {
		param = rb_ary_entry(params, i);
		if (TYPE(param) == T_HASH) {
			param_value_tmp = rb_hash_aref(param, sym_value);
			if(TYPE(param_value_tmp) == T_STRING)
				param_value = param_value_tmp;
			else
				param_value = rb_funcall(param_value_tmp, rb_intern("to_s"), 0);
			param_format = rb_hash_aref(param, sym_format);
		}
		else {
			if(TYPE(param) == T_STRING)
				param_value = param;
			else
				param_value = rb_funcall(param, rb_intern("to_s"), 0);
			param_format = INT2NUM(0);
		}
		Check_Type(param_value, T_STRING);
		paramValues[i] = RSTRING_PTR(param_value);
		paramLengths[i] = RSTRING_LEN(param_value) + 1;
		paramFormats[i] = NUM2INT(param_format);
	}
	
	result = PQsendQueryPrepared(conn, StringValuePtr(name), nParams, 
		(const char * const *)paramValues, paramLengths, paramFormats, 
		resultFormat);

	free(paramValues);
	free(paramLengths);
	free(paramFormats);

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
pgconn_send_describe_prepared(self, stmt_name)
	VALUE self, stmt_name;
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
pgconn_send_describe_portal(self, portal)
	VALUE self, portal;
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
 *
 * Asynchronously send _command_ to the server. Does not block. 
 * Use in combination with +conn.get_result+.
 */
static VALUE
pgconn_get_result(self)
	VALUE self;
{
	PGresult *result;
	VALUE rb_pgresult;

	result = PQgetResult(get_pgconn(self));
	if(result == NULL)
		return Qnil;
	
	rb_pgresult = new_pgresult(result);
	pgresult_check(self, rb_pgresult);
    if (rb_block_given_p()) {
        return rb_ensure(yield_pgresult, rb_pgresult, 
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
 *    conn.setnonblocking() -> Boolean
 *
 * Returns +true+ if a command is busy, that is, if
 * PQgetResult would block. Otherwise returns +false+.
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

/*TODO
 * call-seq:
 *    conn.flush() -> Boolean
 *
 * Returns +true+ if a command is busy, that is, if
 * PQgetResult would block. Otherwise returns +false+.
 */
static VALUE
pgconn_flush(self)
	VALUE self;
{
	//if(PQflush(get_pgconn(self))) 
	return Qnil;
}

//TODO get_cancel

//TODO free_cancel

//TODO cancel

/*
 * call-seq:
 *    conn.notifies()
 *
 * Returns an array of the unprocessed notifiers.
 * If there is no unprocessed notifier, it returns +nil+.
 */
static VALUE
pgconn_notifies(self)
    VALUE self;
{
    PGconn* conn = get_pgconn(self);
    PGnotify *notify;
    VALUE hash;
	VALUE sym_relname, sym_be_pid, sym_extra;
	VALUE relname, be_pid, extra;

	sym_relname = ID2SYM(rb_intern("relname"));
	sym_be_pid = ID2SYM(rb_intern("be_pid"));
	sym_extra = ID2SYM(rb_intern("extra"));

    /* gets notify and builds result */
    notify = PQnotifies(conn);
    if (notify == NULL) {
        /* there are no unhandled notifications */
        return Qnil;
    }
	
	hash = rb_hash_new();
	relname = rb_tainted_str_new2(notify->relname);
	be_pid = INT2NUM(notify->be_pid);
	extra = rb_tainted_str_new2(notify->extra);
	
    rb_hash_aset(hash, sym_relname, relname);
	rb_hash_aset(hash, sym_be_pid, be_pid);
	rb_hash_aset(hash, sym_extra, extra);

    PQfreemem(notify);

    /* returns result */
    return hash;
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
pgconn_put_copy_end(argc, argv, self)
	int argc;
	VALUE *argv;
	VALUE self;
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
pgconn_get_copy_data( argc, argv, self )
	int argc;
	VALUE *argv;
	VALUE self;
{
    VALUE async_in;
	VALUE error;
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
	return rb_str_new(buffer, ret);
}

//TODO set_error_verbosity

/*TODO
 * call-seq:
 *    conn.trace( port )
 * 
 * Enables tracing message passing between backend.
 * The trace message will be written to the _port_ object,
 * which is an instance of the class +File+.
 */
static VALUE
pgconn_trace(self, port)
    VALUE self, port;
{
    //OpenFile* fp;

    Check_Type(port, T_FILE);
    //GetOpenFile(port, fp);

    //PQtrace(get_pgconn(self), fp->f2?fp->f2:fp->f);

    return self;
}

/*
 * call-seq:
 *    conn.untrace()
 * 
 * Disables the message tracing.
 */
static VALUE
pgconn_untrace(self)
    VALUE self;
{
    PQuntrace(get_pgconn(self));
    return self;
}

//TODO set_notice_receiver

//TODO set_notice_processor

/*TODO
 * call-seq:
 *    conn.client_encoding() -> String
 * 
 * Returns the client encoding as a String.
 */
static VALUE
pgconn_client_encoding(self)
    VALUE self;
{
    char *encoding = (char *)pg_encoding_to_char(PQclientEncoding(get_pgconn(self)));
    return rb_tainted_str_new2(encoding);
}

/*TODO
 * call-seq:
 *    conn.set_client_encoding( encoding )
 * 
 * Sets the client encoding to the _encoding_ String.
 */
static VALUE
pgconn_set_client_encoding(self, str)
    VALUE self, str;
{
    Check_Type(str, T_STRING);
    if ((PQsetClientEncoding(get_pgconn(self), StringValuePtr(str))) == -1){
        rb_raise(rb_ePGError, "invalid encoding name %s",StringValuePtr(str));
    }
    return Qnil;
}

/*TODO */
static void
notice_proxy(self, message)
    VALUE self;
    const char *message;
{
    VALUE block;
    if ((block = rb_iv_get(self, "@on_notice")) != Qnil) {
        rb_funcall(block, rb_intern("call"), 1, rb_str_new2(message));
    }
}

/*TODO
 * call-seq:
 *   conn.on_notice {|message| ... }
 *
 * Notice and warning messages generated by the server are not returned
 * by the query execution functions, since they do not imply failure of
 * the query. Instead they are passed to a notice handling function, and
 * execution continues normally after the handler returns. The default
 * notice handling function prints the message on <tt>stderr</tt>, but the
 * application can override this behavior by supplying its own handling
 * function.
 */
static VALUE
pgconn_set_notice_processor(self)
    VALUE self;
{
    VALUE block = rb_block_proc();
    PGconn *conn = get_pgconn(self);
    if (PQsetNoticeProcessor(conn, NULL, NULL) != notice_proxy) {
        PQsetNoticeProcessor(conn, notice_proxy, (void *) self);
    }
    rb_iv_set(self, "@on_notice", block);
    return self;
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
pgconn_locreat(argc, argv, self)
    int argc;
    VALUE *argv;
    VALUE self;
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
pgconn_locreate(self, in_lo_oid)
    VALUE self, in_lo_oid;
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
pgconn_loimport(self, filename)
    VALUE self, filename;
{
    Oid lo_oid;

    PGconn *conn = get_pgconn(self);

    Check_Type(filename, T_STRING);

    lo_oid = lo_import(conn, StringValuePtr(filename));
    if (lo_oid == 0) {
        rb_raise(rb_ePGError, PQerrorMessage(conn));
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
pgconn_loexport(self, lo_oid,filename)
    VALUE self, lo_oid, filename;
{
    PGconn *conn = get_pgconn(self);
    int oid;
    Check_Type(filename, T_STRING);

    oid = NUM2INT(lo_oid);
    if (oid < 0) {
        rb_raise(rb_ePGError, "invalid large object oid %d",oid);
    }

    if (lo_export(conn, oid, StringValuePtr(filename)) < 0) {
        rb_raise(rb_ePGError, PQerrorMessage(conn));
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
pgconn_loopen(argc, argv, self)
    int argc;
    VALUE *argv;
    VALUE self;
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
        rb_raise(rb_ePGError, "can't open large object");
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
pgconn_lowrite(self, in_lo_desc, buffer)
    VALUE self, buffer;
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
        rb_raise(rb_ePGError, "lo_write failed");
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
pgconn_loread(self, in_lo_desc, in_len)
    VALUE self, in_lo_desc, in_len;
{
    int ret;
    PGconn *conn = get_pgconn(self);
    int len = NUM2INT(in_len);
	int lo_desc = NUM2INT(in_lo_desc);
	VALUE str;
	char *buffer;

	buffer = malloc(len);
	if(buffer == NULL)
		rb_raise(rb_eNoMemError, "Malloc failed!");
    
    if (len < 0){
        rb_raise(rb_ePGError,"nagative length %d given", len);
    }

    if((ret = lo_read(conn, lo_desc, buffer, len)) < 0)
        rb_raise(rb_ePGError, "lo_read failed");

	if(ret == 0) {
		free(buffer);
		return Qnil;
	}

	str = rb_tainted_str_new(buffer, len);
	free(buffer);

    return str;
}


/*
 * call-seq
 *    conn.lo_lseek( lo_desc, offset, whence ) -> Fixnum
 *
 * Move the large object pointer _lo_desc_ to offset _offset_.
 * Valid values for _whence_ are +SEEK_SET+, +SEEK_CUR+, and +SEEK_END+.
 * (Or 0, 1, or 2.)
 */
static VALUE
pgconn_lolseek(self, in_lo_desc, offset, whence)
    VALUE self, in_lo_desc, offset, whence;
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
pgconn_lotell(self,in_lo_desc)
    VALUE self, in_lo_desc;
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
pgconn_lotruncate(self, in_lo_desc, in_len)
    VALUE self, in_lo_desc, in_len;
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
pgconn_loclose(self, in_lo_desc)
    VALUE self, in_lo_desc;
{
    PGconn *conn = get_pgconn(self);
    int lo_desc = NUM2INT(in_lo_desc);
    
    if(lo_unlink(conn,lo_desc) < 0)
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
pgconn_lounlink(self, in_oid)
    VALUE self, in_oid;
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
pgresult_result_status(self)
    VALUE self;
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
pgresult_res_status(self,status)
    VALUE self,status;
{
    return rb_str_new2(PQresStatus(NUM2INT(status)));
}

/*
 * call-seq:
 *    res.result_error_message() -> String
 *
 * Returns the error message of the command as a string. 
 */
static VALUE
pgresult_result_error_message(self)
    VALUE self;
{
    return rb_str_new2(PQresultErrorMessage(get_pgresult(self)));
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
pgresult_result_error_field(self)
    VALUE self;
{
    return rb_str_new2(PQresultErrorMessage(get_pgresult(self)));
}

/*
 * call-seq:
 *    res.clear() -> nil
 *
 * Clears the PGresult object as the result of the query.
 */
static VALUE
pgresult_clear(self)
    VALUE self;
{
    PQclear(get_pgresult(self));
    DATA_PTR(self) = 0;
    return Qnil;
}

/*
 * call-seq:
 *    res.ntuples() -> Fixnum
 *
 * Returns the number of tuples in the query result.
 */
static VALUE
pgresult_ntuples(self)
    VALUE self;
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
pgresult_nfields(self)
    VALUE self;
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
pgresult_fname(self, index)
    VALUE self, index;
{
    PGresult *result;
	int i = NUM2INT(index);

    result = get_pgresult(self);
    if (i < 0 || i >= PQnfields(result)) {
        rb_raise(rb_eArgError,"invalid field number %d", i);
    }
    return rb_tainted_str_new2(PQfname(result, i));
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
pgresult_fnumber(self, name)
    VALUE self, name;
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
pgresult_ftable(self, column_number)
    VALUE self, column_number;
{
	Oid n = PQftable(get_pgresult(self), NUM2INT(column_number));
    if (n == InvalidOid) {
        rb_raise(rb_eArgError,"Oid is undefined for column: %d", 
			NUM2INT(column_number));
    }
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
pgresult_ftablecol(self, column_number)
    VALUE self, column_number;
{
	int n = PQftablecol(get_pgresult(self), NUM2INT(column_number));
    if (n == 0) {
        rb_raise(rb_eArgError,
			"Column number from table is undefined for column: %d", 
			NUM2INT(column_number));
    }
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
pgresult_fformat(self, column_number)
    VALUE self, column_number;
{
	PGresult *result = get_pgresult(self);
	int fnumber = NUM2INT(column_number);
    if (fnumber >= PQnfields(result)) {
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
 * The integer returned is the internal +OID+ number (in PostgreSQL) of the type.
 */
static VALUE
pgresult_ftype(self, index)
    VALUE self, index;
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
 * Returns the type modifier associated with column _column_number_.
 * 
 * Raises ArgumentError if _column_number_ is out of range.
 */
static VALUE
pgresult_fmod(self, column_number)
    VALUE self, column_number;
{
	PGresult *result = get_pgresult(self);
	int fnumber = NUM2INT(column_number);
	int modifier;
    if (fnumber >= PQnfields(result)) {
        rb_raise(rb_eArgError, "Column number is out of range: %d", 
			fnumber);
    }
	if((modifier = PQfmod(result,fnumber)) == -1)
		rb_raise(rb_eArgError, 
			"No modifier information available for column: %d", 
			fnumber);
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
pgresult_fsize(self, index)
    VALUE self, index;
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
 * Returns the value in tuple number _tup_num_, field _field_num_. 
 */
static VALUE
pgresult_getvalue(self, tup_num, field_num)
    VALUE self, tup_num, field_num;
{
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
	return rb_str_new2(PQgetvalue(result, i, j));
}

/*
 * call-seq:
 *    res.getisnull(tuple_position, field_position) -> boolean
 *
 * Returns +true+ if the specified value is +nil+; +false+ otherwise.
 */
static VALUE
pgresult_getisnull(self, tup_num, field_num)
    VALUE self, tup_num, field_num;
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
pgresult_getlength(self, tup_num, field_num)
    VALUE self, tup_num, field_num;
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
pgresult_nparams(self)
    VALUE self;
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
pgresult_paramtype(self, param_number)
    VALUE self, param_number;
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
pgresult_cmd_status(self)
    VALUE self;
{
    return rb_tainted_str_new2(PQcmdStatus(get_pgresult(self)));
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
pgresult_cmd_tuples(self)
    VALUE self;
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
pgresult_oid_value(self)
    VALUE self;
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
pgresult_aref(self, index)
	VALUE self, index;
{
	PGresult *result = get_pgresult(self);
	int tuple_num = NUM2INT(index);
	int field_num;
	VALUE fname,val;
	VALUE tuple;

	tuple = rb_hash_new();
	for(field_num = 0; field_num < PQnfields(result); field_num++) {
		fname = rb_str_new2(PQfname(result,field_num));
		if(PQgetisnull(result, tuple_num, field_num)) {
			rb_hash_aset(tuple, fname, Qnil);
		}
		else {
			val = rb_tainted_str_new2(PQgetvalue(result, tuple_num, field_num));
			rb_hash_aset(tuple, fname, val);
		}
	}
	return tuple;
}

/*
 * call-seq:
 *    res.each{ |tuple| ... }
 *
 * Invokes block for each tuple in the result set.
 */
static VALUE
pgresult_each(self)
	VALUE self;
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
pgresult_fields(self)
    VALUE self;
{
    PGresult *result;
    VALUE ary;
    int n, i;

    result = get_pgresult(self);
    n = PQnfields(result);
    ary = rb_ary_new2(n);
    for (i=0;i<n;i++) {
        rb_ary_push(ary, rb_tainted_str_new2(PQfname(result, i)));
    }
    return ary;
}

/**************************************************************************/

void
Init_pg()
{
    rb_ePGError = rb_define_class("PGError", rb_eStandardError);
    rb_cPGconn = rb_define_class("PGconn", rb_cObject);
    rb_cPGresult = rb_define_class("PGresult", rb_cObject);


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
#ifdef HAVE_RB_DEFINE_ALLOC_FUNC
    rb_define_alloc_func(rb_cPGconn, pgconn_alloc);
#else
    rb_define_singleton_method(rb_cPGconn, "new", pgconn_s_new, -1);
#endif  
    rb_define_singleton_alias(rb_cPGconn, "connect", "new");
    rb_define_singleton_alias(rb_cPGconn, "open", "new");
    rb_define_singleton_alias(rb_cPGconn, "setdb", "new");
    rb_define_singleton_alias(rb_cPGconn, "setdblogin", "new");
    rb_define_singleton_alias(rb_cPGconn, "open", "new");
    rb_define_singleton_method(rb_cPGconn, "escape_string", pgconn_s_escape, 1);
	rb_define_singleton_alias(rb_cPGconn, "escape", "escape_string");
    rb_define_singleton_method(rb_cPGconn, "escape_bytea", pgconn_s_escape_bytea, 1);
    rb_define_singleton_method(rb_cPGconn, "unescape_bytea", pgconn_s_unescape_bytea, 1);
    rb_define_singleton_method(rb_cPGconn, "isthreadsafe", pgconn_s_isthreadsafe, 0);
    rb_define_singleton_method(rb_cPGconn, "encrypt_password", pgconn_s_encrypt_password, 0);

	/******     PGconn CLASS CONSTANTS: Connection Status     ******/
    rb_define_const(rb_cPGconn, "CONNECTION_OK", INT2FIX(CONNECTION_OK));
    rb_define_const(rb_cPGconn, "CONNECTION_BAD", INT2FIX(CONNECTION_BAD));

	/******     PGconn CLASS CONSTANTS: Nonblocking connection status     ******/
	rb_define_const(rb_cPGconn, "CONNECTION_STARTED", INT2FIX(CONNECTION_STARTED));
	rb_define_const(rb_cPGconn, "CONNECTION_MADE", INT2FIX(CONNECTION_MADE));
	rb_define_const(rb_cPGconn, "CONNECTION_AWAITING_RESPONSE", INT2FIX(CONNECTION_AWAITING_RESPONSE));
	rb_define_const(rb_cPGconn, "CONNECTION_AUTH_OK", INT2FIX(CONNECTION_AUTH_OK));
	rb_define_const(rb_cPGconn, "CONNECTION_SSL_STARTUP", INT2FIX(CONNECTION_SSL_STARTUP));
	rb_define_const(rb_cPGconn, "CONNECTION_SETENV", INT2FIX(CONNECTION_SETENV));
	
	/******     PGconn CLASS CONSTANTS: Nonblocking connection polling status     ******/
	rb_define_const(rb_cPGconn, "PGRES_POLLING_READING", INT2FIX(PGRES_POLLING_READING));
	rb_define_const(rb_cPGconn, "PGRES_POLLING_WRITING", INT2FIX(PGRES_POLLING_WRITING));
	rb_define_const(rb_cPGconn, "PGRES_POLLING_FAILED", INT2FIX(PGRES_POLLING_FAILED));
	rb_define_const(rb_cPGconn, "PGRES_POLLING_OK", INT2FIX(PGRES_POLLING_OK));

	/******     PGconn CLASS CONSTANTS: Transaction Status     ******/
	rb_define_const(rb_cPGconn, "PQTRANS_IDLE", INT2FIX(PQTRANS_IDLE));
	rb_define_const(rb_cPGconn, "PQTRANS_ACTIVE", INT2FIX(PQTRANS_ACTIVE));
	rb_define_const(rb_cPGconn, "PQTRANS_INTRANS", INT2FIX(PQTRANS_INTRANS));
	rb_define_const(rb_cPGconn, "PQTRANS_INERROR", INT2FIX(PQTRANS_INERROR));
	rb_define_const(rb_cPGconn, "PQTRANS_UNKNOWN", INT2FIX(PQTRANS_UNKNOWN));

	/******     PGconn CLASS CONSTANTS: Large Objects     ******/
    rb_define_const(rb_cPGconn, "INV_WRITE", INT2FIX(INV_WRITE));
    rb_define_const(rb_cPGconn, "INV_READ", INT2FIX(INV_READ));
    rb_define_const(rb_cPGconn, "SEEK_SET", INT2FIX(SEEK_SET));
    rb_define_const(rb_cPGconn, "SEEK_CUR", INT2FIX(SEEK_CUR));
    rb_define_const(rb_cPGconn, "SEEK_END", INT2FIX(SEEK_END));
    
	/******     PGconn INSTANCE METHODS: Connection Control     ******/
    rb_define_method(rb_cPGconn, "initialize", pgconn_init, -1);
    rb_define_method(rb_cPGconn, "reset", pgconn_reset, 0);
    rb_define_method(rb_cPGconn, "finish", pgconn_finish, 0);

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
    //rb_define_method(rb_cPGconn, "socket", pgconn_socket, 0);
    rb_define_method(rb_cPGconn, "backend_pid", pgconn_backend_pid, 0);
    rb_define_method(rb_cPGconn, "connection_needs_password", pgconn_connection_needs_password, 0);
    rb_define_method(rb_cPGconn, "connection_used_password", pgconn_connection_used_password, 0);
    //rb_define_method(rb_cPGconn, "getssl", pgconn_getssl, 0);

	/******     PGconn INSTANCE METHODS: Command Execution     ******/
    rb_define_method(rb_cPGconn, "exec", pgconn_exec, 1);
    rb_define_method(rb_cPGconn, "exec_params", pgconn_exec_params, -1);
    rb_define_method(rb_cPGconn, "prepare", pgconn_prepare, -1);
    rb_define_method(rb_cPGconn, "exec_prepared", pgconn_exec_prepared, -1);
    rb_define_method(rb_cPGconn, "describe_prepared", pgconn_describe_prepared, 1);
    rb_define_method(rb_cPGconn, "describe_portal", pgconn_describe_portal, 1);
    rb_define_method(rb_cPGconn, "escape_string", pgconn_s_escape, 1);
	rb_define_alias(rb_cPGconn, "escape", "escape_string");
    rb_define_method(rb_cPGconn, "escape_bytea", pgconn_s_escape_bytea, 1);
    rb_define_method(rb_cPGconn, "unescape_bytea", pgconn_s_unescape_bytea, 1);
 
	/******     PGconn INSTANCE METHODS: Asynchronous Command Processing     ******/
    rb_define_method(rb_cPGconn, "send_query", pgconn_send_query, 0);
    rb_define_method(rb_cPGconn, "send_query_params", pgconn_send_query_params, 0);
    rb_define_method(rb_cPGconn, "send_prepare", pgconn_send_prepare, 0);
    rb_define_method(rb_cPGconn, "send_query_prepared", pgconn_send_query_prepared, 0);
    rb_define_method(rb_cPGconn, "send_describe_prepared", pgconn_send_describe_prepared, 0);
    rb_define_method(rb_cPGconn, "send_describe_portal", pgconn_send_describe_portal, 0);
    rb_define_method(rb_cPGconn, "get_result", pgconn_get_result, 0);
    rb_define_method(rb_cPGconn, "consume_input", pgconn_consume_input, 0);
    rb_define_method(rb_cPGconn, "is_busy", pgconn_is_busy, 0);
    rb_define_method(rb_cPGconn, "setnonblocking", pgconn_setnonblocking, 1);
    rb_define_method(rb_cPGconn, "isnonblocking", pgconn_isnonblocking, 0);
    rb_define_method(rb_cPGconn, "flush", pgconn_flush, 0);

	/******     PGconn INSTANCE METHODS: Cancelling Queries in Progress     ******/
	//rb_define_method(rb_cPGconn, "get_cancel", pgconn_get_result, 0);
	//rb_define_method(rb_cPGconn, "free_cancel", pgconn_get_result, 0);
	//rb_define_method(rb_cPGconn, "cancel", pgconn_get_result, 0);

	/******     PGconn INSTANCE METHODS: NOTIFY     ******/
    rb_define_method(rb_cPGconn, "notifies", pgconn_notifies, 0);

	/******     PGconn INSTANCE METHODS: COPY     ******/
    rb_define_method(rb_cPGconn, "put_copy_data", pgconn_put_copy_data, 1);
    rb_define_method(rb_cPGconn, "put_copy_end", pgconn_put_copy_end, -1);
    rb_define_method(rb_cPGconn, "get_copy_data", pgconn_get_copy_data, -1);

	/******     PGconn INSTANCE METHODS: Control Functions     ******/
    //rb_define_method(rb_cPGconn, "set_error_verbosity", pgconn_set_error_verbosity, 0);
    rb_define_method(rb_cPGconn, "trace", pgconn_trace, 1);
    rb_define_method(rb_cPGconn, "untrace", pgconn_untrace, 0);

	/******     PGconn INSTANCE METHODS: Notice Processing     ******/
    //rb_define_method(rb_cPGconn, "set_notice_receiver", pgconn_set_notice_receiver, 0);
    rb_define_method(rb_cPGconn, "set_notice_processor", pgconn_set_notice_processor, 0);

	/******     PGconn INSTANCE METHODS: Other TODO    ******/
    rb_define_method(rb_cPGconn, "client_encoding", pgconn_client_encoding, 0);
    rb_define_method(rb_cPGconn, "set_client_encoding", pgconn_set_client_encoding, 1);

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
    rb_define_const(rb_cPGresult, "PGRES_EMPTY_QUERY", INT2FIX(PGRES_EMPTY_QUERY));
    rb_define_const(rb_cPGresult, "PGRES_COMMAND_OK", INT2FIX(PGRES_COMMAND_OK));
    rb_define_const(rb_cPGresult, "PGRES_TUPLES_OK", INT2FIX(PGRES_TUPLES_OK));
    rb_define_const(rb_cPGresult, "PGRES_COPY_OUT", INT2FIX(PGRES_COPY_OUT));
    rb_define_const(rb_cPGresult, "PGRES_COPY_IN", INT2FIX(PGRES_COPY_IN));
    rb_define_const(rb_cPGresult, "PGRES_BAD_RESPONSE", INT2FIX(PGRES_BAD_RESPONSE));
    rb_define_const(rb_cPGresult, "PGRES_NONFATAL_ERROR",INT2FIX(PGRES_NONFATAL_ERROR));
    rb_define_const(rb_cPGresult, "PGRES_FATAL_ERROR", INT2FIX(PGRES_FATAL_ERROR));

	/******     PGresult CONSTANTS: result error field codes      ******/
	rb_define_const(rb_cPGresult, "PG_DIAG_SEVERITY", INT2FIX(PG_DIAG_SEVERITY));
	rb_define_const(rb_cPGresult, "PG_DIAG_SQLSTATE", INT2FIX(PG_DIAG_SQLSTATE));
	rb_define_const(rb_cPGresult, "PG_DIAG_MESSAGE_PRIMARY", INT2FIX(PG_DIAG_MESSAGE_PRIMARY));
	rb_define_const(rb_cPGresult, "PG_DIAG_MESSAGE_DETAIL", INT2FIX(PG_DIAG_MESSAGE_DETAIL));
	rb_define_const(rb_cPGresult, "PG_DIAG_MESSAGE_HINT", INT2FIX(PG_DIAG_MESSAGE_HINT));
	rb_define_const(rb_cPGresult, "PG_DIAG_STATEMENT_POSITION", INT2FIX(PG_DIAG_STATEMENT_POSITION));
	rb_define_const(rb_cPGresult, "PG_DIAG_INTERNAL_POSITION", INT2FIX(PG_DIAG_INTERNAL_POSITION));
	rb_define_const(rb_cPGresult, "PG_DIAG_INTERNAL_QUERY", INT2FIX(PG_DIAG_INTERNAL_QUERY));
	rb_define_const(rb_cPGresult, "PG_DIAG_CONTEXT", INT2FIX(PG_DIAG_CONTEXT));
	rb_define_const(rb_cPGresult, "PG_DIAG_SOURCE_FILE", INT2FIX(PG_DIAG_SOURCE_FILE));
	rb_define_const(rb_cPGresult, "PG_DIAG_SOURCE_LINE", INT2FIX(PG_DIAG_SOURCE_LINE));
	rb_define_const(rb_cPGresult, "PG_DIAG_SOURCE_FUNCTION", INT2FIX(PG_DIAG_SOURCE_FUNCTION));

	/******     PGresult INSTANCE METHODS: libpq     ******/
    rb_define_method(rb_cPGresult, "result_status", pgresult_result_status, 0);
    rb_define_method(rb_cPGresult, "res_status", pgresult_res_status, 1);
    rb_define_method(rb_cPGresult, "result_error_message", pgresult_result_error_message, 0);
    rb_define_method(rb_cPGresult, "result_error_field", pgresult_result_error_field, 0);
    rb_define_method(rb_cPGresult, "ntuples", pgresult_ntuples, 0);
    rb_define_method(rb_cPGresult, "nfields", pgresult_nfields, 0);
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
	rb_define_method(rb_cPGresult, "paramtype", pgresult_paramtype, 0);
	rb_define_method(rb_cPGresult, "cmd_status", pgresult_cmd_status, 0);
	rb_define_method(rb_cPGresult, "cmd_tuples", pgresult_cmd_tuples, 0);
	rb_define_method(rb_cPGresult, "oid_value", pgresult_oid_value, 0);
    rb_define_method(rb_cPGresult, "clear", pgresult_clear, 0);

	/******     PGresult INSTANCE METHODS: other     ******/
    rb_define_method(rb_cPGresult, "[]", pgresult_aref, 1);
    rb_define_method(rb_cPGresult, "each", pgresult_each, 0);
    rb_define_method(rb_cPGresult, "fields", pgresult_fields, 0);

}

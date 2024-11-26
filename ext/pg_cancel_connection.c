#include "pg.h"

/********************************************************************
 *
 * Document-class: PG::CancelConnection
 *
 * The class to represent a connection to cancel a query.
 * An instance of this class can be created by PG::Connection#cancel .
 *
 */

#ifdef HAVE_PQSETCHUNKEDROWSMODE

static VALUE rb_cPG_Cancon;
static ID s_id_autoclose_set;

typedef struct {
	PGcancelConn *pg_cancon;

	/* Cached IO object for the socket descriptor */
	VALUE socket_io;

#if defined(_WIN32)
	/* File descriptor to be used for rb_w32_unwrap_io_handle() */
	int ruby_sd;
#endif
} t_pg_cancon;


/*
 * GC Mark function
 */
static void
pg_cancon_gc_mark( void *_this )
{
	t_pg_cancon *this = (t_pg_cancon *)_this;
	rb_gc_mark_movable( this->socket_io );
}

static void
pg_cancon_gc_compact( void *_this )
{
	t_pg_connection *this = (t_pg_connection *)_this;
	pg_gc_location( this->socket_io );
}

static void
pg_cancon_gc_free( void *_this )
{
	t_pg_cancon *this = (t_pg_cancon *)_this;
#if defined(_WIN32)
	if ( RTEST(this->socket_io) ) {
		if( rb_w32_unwrap_io_handle(this->ruby_sd) ){
			rb_warn("pg: Could not unwrap win32 socket handle by garbage collector");
		}
	}
#endif
	if (this->pg_cancon)
		PQcancelFinish(this->pg_cancon);
	xfree(this);
}

static size_t
pg_cancon_memsize( const void *_this )
{
	const t_pg_cancon *this = (const t_pg_cancon *)_this;
	return sizeof(*this);
}

static const rb_data_type_t pg_cancon_type = {
	"PG::CancelConnection",
	{
		pg_cancon_gc_mark,
		pg_cancon_gc_free,
		pg_cancon_memsize,
		pg_cancon_gc_compact,
	},
	0, 0,
	RUBY_TYPED_FREE_IMMEDIATELY | RUBY_TYPED_WB_PROTECTED | PG_RUBY_TYPED_FROZEN_SHAREABLE,
};

/*
 * Document-method: allocate
 *
 * call-seq:
 *   PG::VeryTuple.allocate -> obj
 */
static VALUE
pg_cancon_s_allocate( VALUE klass )
{
	t_pg_cancon *this;
	return TypedData_Make_Struct( klass, t_pg_cancon, &pg_cancon_type, this );
}

static inline t_pg_cancon *
pg_cancon_get_this( VALUE self )
{
	t_pg_cancon *this;
	TypedData_Get_Struct(self, t_pg_cancon, &pg_cancon_type, this);

	return this;
}

static inline PGcancelConn *
pg_cancon_get_conn( VALUE self )
{
	t_pg_cancon *this = pg_cancon_get_this(self);
	if (this->pg_cancon == NULL)
		pg_raise_conn_error( rb_eConnectionBad, self, "PG::CancelConnection is closed");

	return this->pg_cancon;
}

/*
 * Close the associated socket IO object if there is one.
 */
static void
pg_cancon_close_socket_io( VALUE self )
{
	t_pg_cancon *this = pg_cancon_get_this( self );
	VALUE socket_io = this->socket_io;

	if ( RTEST(socket_io) ) {
#if defined(_WIN32)
		if( rb_w32_unwrap_io_handle(this->ruby_sd) )
			pg_raise_conn_error( rb_eConnectionBad, self, "Could not unwrap win32 socket handle");
#endif
		rb_funcall( socket_io, rb_intern("close"), 0 );
	}

	RB_OBJ_WRITE(self, &this->socket_io, Qnil);
}

VALUE
pg_cancon_initialize(VALUE self, VALUE rb_conn)
{
	t_pg_cancon *this = pg_cancon_get_this(self);
	PGconn *conn = pg_get_pgconn(rb_conn);

	this->pg_cancon = PQcancelCreate(conn);

	return self;
}

/*
 * call-seq:
 *    conn.sync_cancel -> nil
 *
 * Requests that the server abandons processing of the current command in a blocking manner.
 *
 * If the cancel request wasn't successfully dispatched an error message is raised.
 *
 * Successful dispatch of the cancellation is no guarantee that the request will have any effect, however.
 * If the cancellation is effective, the command being canceled will terminate early and raises an error.
 * If the cancellation fails (say, because the server was already done processing the command), then there will be no visible result at all.
 *
 */
static VALUE
pg_cancon_sync_cancel(VALUE self)
{
	PGcancelConn *conn = pg_cancon_get_conn(self);

	pg_cancon_close_socket_io( self );
	if(gvl_PQcancelBlocking(conn) == 0)
		pg_raise_conn_error( rb_eConnectionBad, self, "PQcancelBlocking %s", PQcancelErrorMessage(conn));
	return Qnil;
}

/*
 * call-seq:
 *    conn.start -> nil
 *
 */
static VALUE
pg_cancon_start(VALUE self)
{
	PGcancelConn *conn = pg_cancon_get_conn(self);

	pg_cancon_close_socket_io( self );
	if(gvl_PQcancelStart(conn) == 0)
		pg_raise_conn_error( rb_eConnectionBad, self, "PQcancelStart %s", PQcancelErrorMessage(conn));
	return Qnil;
}

/*
 * call-seq:
 *    conn.error_message -> String
 *
 */
static VALUE
pg_cancon_error_message(VALUE self)
{
	PGcancelConn *conn = pg_cancon_get_conn(self);
	char *p_err;

	p_err = PQcancelErrorMessage(conn);

	return p_err ? rb_str_new_cstr(p_err) : Qnil;
}

/*
 * call-seq:
 *    conn.poll -> nil
 *
 */
static VALUE
pg_cancon_poll(VALUE self)
{
	PostgresPollingStatusType status;
	PGcancelConn *conn = pg_cancon_get_conn(self);

	pg_cancon_close_socket_io( self );
	status = gvl_PQcancelPoll(conn);

	return INT2FIX((int)status);
}

/*
 * call-seq:
 *    conn.status -> nil
 *
 */
static VALUE
pg_cancon_status(VALUE self)
{
	ConnStatusType status;
	PGcancelConn *conn = pg_cancon_get_conn(self);

	status = PQcancelStatus(conn);

	return INT2NUM(status);
}

/*
 * call-seq:
 *    conn.socket_io() -> IO
 *
 * Fetch an IO object created from the CancelConnection's underlying socket.
 * This object can be used per <tt>socket_io.wait_readable</tt>, <tt>socket_io.wait_writable</tt> or for <tt>IO.select</tt> to wait for events while running asynchronous API calls.
 * <tt>IO#wait_*able</tt> is is <tt>Fiber.scheduler</tt> compatible in contrast to <tt>IO.select</tt>.
 *
 * The IO object can change while the connection is established.
 * So be sure not to cache the IO object, but repeat calling <tt>conn.socket_io</tt> instead.
 */
static VALUE
pg_cancon_socket_io(VALUE self)
{
	int sd;
	int ruby_sd;
	t_pg_cancon *this = pg_cancon_get_this( self );
	VALUE cSocket;
	VALUE socket_io = this->socket_io;

	if ( !RTEST(socket_io) ) {
		if( (sd = PQcancelSocket(this->pg_cancon)) < 0){
			pg_raise_conn_error( rb_eConnectionBad, self, "PQcancelSocket() can't get socket descriptor");
		}

		#ifdef _WIN32
			ruby_sd = rb_w32_wrap_io_handle((HANDLE)(intptr_t)sd, O_RDWR|O_BINARY|O_NOINHERIT);
			if( ruby_sd == -1 )
				pg_raise_conn_error( rb_eConnectionBad, self, "Could not wrap win32 socket handle");

			this->ruby_sd = ruby_sd;
		#else
			ruby_sd = sd;
		#endif

		cSocket = rb_const_get(rb_cObject, rb_intern("BasicSocket"));
		socket_io = rb_funcall( cSocket, rb_intern("for_fd"), 1, INT2NUM(ruby_sd));

		/* Disable autoclose feature */
		rb_funcall( socket_io, s_id_autoclose_set, 1, Qfalse );

		RB_OBJ_WRITE(self, &this->socket_io, socket_io);
	}

	return socket_io;
}

/*
 * call-seq:
 *    conn.reset -> nil
 *
 */
static VALUE
pg_cancon_reset(VALUE self)
{
	PGcancelConn *conn = pg_cancon_get_conn(self);

	pg_cancon_close_socket_io( self );
	PQcancelReset(conn);

	return Qnil;
}

static VALUE
pg_cancon_finish(VALUE self)
{
	t_pg_cancon *this = pg_cancon_get_this( self );

	pg_cancon_close_socket_io( self );
	if( this->pg_cancon )
		PQcancelFinish(this->pg_cancon);
	this->pg_cancon = NULL;

	return Qnil;
}
#endif

void
init_pg_cancon(void)
{
#ifdef HAVE_PQSETCHUNKEDROWSMODE
	s_id_autoclose_set = rb_intern("autoclose=");

	rb_cPG_Cancon = rb_define_class_under( rb_mPG, "CancelConnection", rb_cObject );
	rb_define_alloc_func( rb_cPG_Cancon, pg_cancon_s_allocate );
	rb_include_module(rb_cPG_Cancon, rb_mEnumerable);

	rb_define_method(rb_cPG_Cancon, "initialize", pg_cancon_initialize, 1);
	rb_define_method(rb_cPG_Cancon, "sync_cancel", pg_cancon_sync_cancel, 0);
	rb_define_method(rb_cPG_Cancon, "start", pg_cancon_start, 0);
	rb_define_method(rb_cPG_Cancon, "poll", pg_cancon_poll, 0);
	rb_define_method(rb_cPG_Cancon, "status", pg_cancon_status, 0);
	rb_define_method(rb_cPG_Cancon, "socket_io", pg_cancon_socket_io, 0);
	rb_define_method(rb_cPG_Cancon, "error_message", pg_cancon_error_message, 0);
	rb_define_method(rb_cPG_Cancon, "reset", pg_cancon_reset, 0);
	rb_define_method(rb_cPG_Cancon, "finish", pg_cancon_finish, 0);
#endif
}

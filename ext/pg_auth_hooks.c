/*
 * pg_auth_hooks.c - Auth hooks for PG module
 * $Id$
 *
 */

#include "pg.h"

#ifdef LIBPQ_HAS_PROMPT_OAUTH_DEVICE

/*
 * We store the pgconn pointers in a register to retrieve the PG::Connection VALUE in the oauth hook.
 */
struct st_table *pgconn2value;
rb_nativethread_lock_t pgconn2value_lock;

static VALUE rb_cPromptOAuthDevice;
static VALUE rb_cOAuthBearerRequest;

int pgconn_lookup(PGconn *pgconn, VALUE *rb_conn){
	int res;
	rb_nativethread_lock_lock(&pgconn2value_lock);
	res = st_lookup(pgconn2value, (st_data_t)pgconn, (st_data_t*)rb_conn);
	rb_nativethread_lock_unlock(&pgconn2value_lock);
	return res;
}

void pgconn_insert(PGconn *pgconn, VALUE rb_conn) {
	rb_nativethread_lock_lock(&pgconn2value_lock);
	st_insert( pgconn2value, (st_data_t)pgconn, (st_data_t)rb_conn );
	rb_nativethread_lock_unlock(&pgconn2value_lock);
}

void pgconn_delete(PGconn *pgconn) {
	rb_nativethread_lock_lock(&pgconn2value_lock);
	st_delete( pgconn2value, (st_data_t*)&pgconn, NULL );
	rb_nativethread_lock_unlock(&pgconn2value_lock);
}


/*
 * Document-class: PG::PromptOAuthDevice
 */

typedef struct {
	PGpromptOAuthDevice *prompt;
} t_pg_prompt_oauth_device;

static size_t
pg_prompt_oauth_device_memsize(const void *_this)
{
	return sizeof(t_pg_prompt_oauth_device);
}

static const rb_data_type_t pg_prompt_oauth_device_type = {
	"PG::PromptOAuthDevice",
	{
		NULL,
		RUBY_TYPED_DEFAULT_FREE,
		pg_prompt_oauth_device_memsize,
		NULL,
	},
	0,
	0,
	RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FREE_IMMEDIATELY,
};

static t_pg_prompt_oauth_device *
pg_get_prompt_oauth_device_safe(VALUE self)
{
	t_pg_prompt_oauth_device *this;

	TypedData_Get_Struct(self, t_pg_prompt_oauth_device, &pg_prompt_oauth_device_type, this);

	if (!this->prompt)
		rb_raise(rb_ePGerror, "data cannot be accessed after callback has completed");

	return this;
}

/*
 * call-seq:
 *    prompt.verification_uri -> String
 */
static VALUE
pg_prompt_oauth_device_verification_uri(VALUE self)
{
	t_pg_prompt_oauth_device *this = pg_get_prompt_oauth_device_safe(self);

	if (!this->prompt->verification_uri)
		rb_raise(rb_ePGerror, "internal error: verification_uri is missing");

	return rb_str_new_cstr(this->prompt->verification_uri);
}

/*
 * call-seq:
 *    prompt.user_code -> String
 */
static VALUE
pg_prompt_oauth_device_user_code(VALUE self)
{
	t_pg_prompt_oauth_device *this = pg_get_prompt_oauth_device_safe(self);

	if (!this->prompt->user_code)
		rb_raise(rb_ePGerror, "internal error: user_code is missing");

	return rb_str_new_cstr(this->prompt->user_code);
}

/*
 * call-seq:
 *    prompt.verification_uri_complete -> String | nil
 */
static VALUE
pg_prompt_oauth_device_verification_uri_complete(VALUE self)
{
	t_pg_prompt_oauth_device *this = pg_get_prompt_oauth_device_safe(self);

	return this->prompt->verification_uri_complete ? rb_str_new_cstr(this->prompt->verification_uri_complete) : Qnil;
}

/*
 * call-seq:
 *    prompt.expires_in -> Integer
 */
static VALUE
pg_prompt_oauth_device_expires_in(VALUE self)
{
	t_pg_prompt_oauth_device *this = pg_get_prompt_oauth_device_safe(self);

	return INT2FIX(this->prompt->expires_in);
}

/*
 * Document-class: PG::OAuthBearerRequest
 */

typedef struct {
	PGoauthBearerRequest *request;
} t_pg_oauth_bearer_request;

static size_t
pg_oauth_bearer_request_memsize(const void *_this)
{
	return sizeof(t_pg_oauth_bearer_request);
}

static const rb_data_type_t pg_oauth_bearer_request_type = {
	"PG::OAuthBearerRequest",
	{
		NULL,
		RUBY_TYPED_DEFAULT_FREE,
		pg_oauth_bearer_request_memsize,
		NULL,
	},
	0,
	0,
	RUBY_TYPED_WB_PROTECTED | RUBY_TYPED_FREE_IMMEDIATELY,
};

static t_pg_oauth_bearer_request *
pg_get_oauth_bearer_request_safe(VALUE self)
{
	t_pg_oauth_bearer_request *this;

	TypedData_Get_Struct(self, t_pg_oauth_bearer_request, &pg_oauth_bearer_request_type, this);

	if (!this->request)
		rb_raise(rb_ePGerror, "data cannot be accessed after callback has completed");

	return this;
}

/*
 * call-seq:
 *    prompt.openid_configuration -> String
 */
static VALUE
pg_oauth_bearer_request_openid_configuration(VALUE self)
{
	t_pg_oauth_bearer_request *this = pg_get_oauth_bearer_request_safe(self);

	if (!this->request->openid_configuration)
		rb_raise(rb_ePGerror, "internal error: openid_configuration is missing");

	return rb_str_new_cstr(this->request->openid_configuration);
}

/*
 * call-seq:
 *    request.scope -> String | nil
 */
static VALUE
pg_oauth_bearer_request_scope(VALUE self)
{
	t_pg_oauth_bearer_request *this = pg_get_oauth_bearer_request_safe(self);

	return this->request->scope ? rb_str_new_cstr(this->request->scope) : Qnil;
}

/*
 * call-seq:
 *    request.token = token
 *
 * See also #token
 */
static VALUE
pg_oauth_bearer_request_token_set(VALUE self, VALUE token)
{
	t_pg_oauth_bearer_request *this = pg_get_oauth_bearer_request_safe(self);

	/* This can throw an exception so needs to be done before free() */
	char *token_cstr = NIL_P(token) ? NULL : strdup(StringValueCStr(token));

	if (this->request->token)
		free(this->request->token);

	this->request->token = token_cstr;

	return token;
}

/*
 * call-seq:
 *    request.token -> String | nil
 *
 * See also #token=
 */
static VALUE
pg_oauth_bearer_request_token_get(VALUE self)
{
	t_pg_oauth_bearer_request *this = pg_get_oauth_bearer_request_safe(self);

	return this->request->token ? rb_str_new_cstr(this->request->token) : Qnil;
}

static void
oauth_bearer_request_cleanup(PGconn *_conn, struct PGoauthBearerRequest *request)
{
	if (request->token)
		free(request->token);
}

static VALUE
call_auth_data_hook(VALUE args)
{
	VALUE proc = ((VALUE*)args)[0];
	VALUE conn_num = ((VALUE*)args)[1];
	VALUE v_data = ((VALUE*)args)[2];

	return rb_funcall(proc, rb_intern("call"), 2, conn_num, v_data);
}

static VALUE
prompt_oauth_device_hook_cleanup(VALUE self, VALUE ex)
{
	t_pg_prompt_oauth_device *this = pg_get_prompt_oauth_device_safe(self);

	this->prompt = NULL;

	rb_exc_raise(ex);
}

static VALUE
oauth_bearer_request_hook_cleanup(VALUE self, VALUE ex)
{
	t_pg_oauth_bearer_request *this = pg_get_oauth_bearer_request_safe(self);

	if (this->request->token)
		free(this->request->token);
	this->request->token = NULL;

	this->request = NULL;

	rb_exc_raise(ex);
}

/*
 * Auth data proxy function -- delegate the callback to the
 * currently-registered Ruby auth_data_hook object.
 */
int
auth_data_hook_proxy(PGauthData type, PGconn *pgconn, void *data)
{
	VALUE rb_conn = Qnil;
	VALUE ret = Qnil;

	if ( st_lookup(pgconn2value, (st_data_t)pgconn, (st_data_t*)&rb_conn) ) {
		t_pg_connection *this = pg_get_connection( rb_conn );
		VALUE proc = this->auth_data_hook;

		if (type == PQAUTHDATA_PROMPT_OAUTH_DEVICE) {
			t_pg_prompt_oauth_device *prompt;

			VALUE v_prompt = TypedData_Make_Struct(rb_cPromptOAuthDevice, t_pg_prompt_oauth_device, &pg_prompt_oauth_device_type, prompt);
			VALUE args[] = { proc, rb_conn, v_prompt };

			prompt->prompt = data;

			ret = rb_rescue(call_auth_data_hook, (VALUE)&args, prompt_oauth_device_hook_cleanup, v_prompt);

			prompt->prompt = NULL;
		} else if (type == PQAUTHDATA_OAUTH_BEARER_TOKEN) {
			t_pg_oauth_bearer_request *request;

			VALUE v_request = TypedData_Make_Struct(rb_cOAuthBearerRequest, t_pg_oauth_bearer_request, &pg_oauth_bearer_request_type, request);
			VALUE args[] = { proc, rb_conn, v_request };

			request->request = data;
			request->request->cleanup = oauth_bearer_request_cleanup;

			ret = rb_rescue(call_auth_data_hook, (VALUE)&args, oauth_bearer_request_hook_cleanup, v_request);

			request->request = NULL;
		}
	}

  /* TODO: a hook can return 1, 0 or -1 */
	return RTEST(ret);
}

/*
 * call-seq:
 *    PG.pgconn2value_size -> Integer
 */
static VALUE
pg_oauth_pgconn2value_size_get(VALUE self)
{
	return SIZET2NUM(rb_st_table_size(pgconn2value));
}


void
init_pg_auth_hooks(void)
{

	pgconn2value = st_init_numtable();
	rb_nativethread_lock_initialize(&pgconn2value_lock);

	PQsetAuthDataHook(gvl_auth_data_hook_proxy); // TODO: Add some safeguards?

	/* rb_mPG = rb_define_module("PG") */
	rb_define_private_method(rb_singleton_class(rb_mPG), "pgconn2value_size", pg_oauth_pgconn2value_size_get, 0);

	rb_cPromptOAuthDevice = rb_define_class_under(rb_mPG, "PromptOAuthDevice", rb_cObject);
	rb_undef_alloc_func(rb_cPromptOAuthDevice);

	rb_define_method(rb_cPromptOAuthDevice, "verification_uri", pg_prompt_oauth_device_verification_uri, 0);
	rb_define_method(rb_cPromptOAuthDevice, "user_code", pg_prompt_oauth_device_user_code, 0);
	rb_define_method(rb_cPromptOAuthDevice, "verification_uri_complete", pg_prompt_oauth_device_verification_uri_complete, 0);
	rb_define_method(rb_cPromptOAuthDevice, "expires_in", pg_prompt_oauth_device_expires_in, 0);

	rb_cOAuthBearerRequest = rb_define_class_under(rb_mPG, "OAuthBearerRequest", rb_cObject);
	rb_undef_alloc_func(rb_cOAuthBearerRequest);

	rb_define_method(rb_cOAuthBearerRequest, "openid_configuration", pg_oauth_bearer_request_openid_configuration, 0);
	rb_define_method(rb_cOAuthBearerRequest, "scope", pg_oauth_bearer_request_scope, 0);
	rb_define_method(rb_cOAuthBearerRequest, "token=", pg_oauth_bearer_request_token_set, 1);
	rb_define_method(rb_cOAuthBearerRequest, "token", pg_oauth_bearer_request_token_get, 0);
}

#else

void init_pg_auth_hooks(void) {}

#endif

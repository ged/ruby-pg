/*
 * pg_auth_hooks.c - Auth hooks for PG module
 * $Id$
 *
 */

#include "pg.h"

#ifdef LIBPQ_HAS_PROMPT_OAUTH_DEVICE

#ifdef TRUFFLERUBY
static VALUE auth_data_hook;
#else
/*
 * On Ruby verisons which support Ractors we store the global callback once
 * per Ractor.
 */
#include "ruby/ractor.h"
static rb_ractor_local_key_t auth_data_hook_key;
#endif

static void
auth_data_hook_init(void)
{
#ifdef TRUFFLERUBY
	auth_data_hook = Qnil;
	rb_gc_register_address(&auth_data_hook);
#else
	auth_data_hook_key = rb_ractor_local_storage_value_newkey();
#endif
}

static VALUE
auth_data_hook_get(void)
{
#ifdef TRUFFLERUBY
	return auth_data_hook;
#else
	VALUE hook = Qnil;
	rb_ractor_local_storage_value_lookup(auth_data_hook_key, &hook);
	return hook;
#endif
}

static void
auth_data_hook_set(VALUE hook)
{
#ifdef TRUFFLERUBY
	auth_data_hook = hook;
#else
	rb_ractor_local_storage_value_set(auth_data_hook_key, hook);
#endif
}

static VALUE rb_cPromptOAuthDevice;
static VALUE rb_cOAuthBearerRequest;

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
auth_data_hook_proxy(PGauthData type, PGconn *conn, void *data)
{
	VALUE proc = auth_data_hook_get(), ret = Qnil;

	if (proc != Qnil) {
		if (type == PQAUTHDATA_PROMPT_OAUTH_DEVICE) {
			t_pg_prompt_oauth_device *prompt;

			VALUE v_prompt = TypedData_Make_Struct(rb_cPromptOAuthDevice, t_pg_prompt_oauth_device, &pg_prompt_oauth_device_type, prompt);
			VALUE args[] = { proc, PTR2NUM(conn), v_prompt };

			prompt->prompt = data;

			ret = rb_rescue(call_auth_data_hook, (VALUE)&args, prompt_oauth_device_hook_cleanup, v_prompt);

			prompt->prompt = NULL;
		} else if (type == PQAUTHDATA_OAUTH_BEARER_TOKEN) {
			t_pg_oauth_bearer_request *request;

			VALUE v_request = TypedData_Make_Struct(rb_cOAuthBearerRequest, t_pg_oauth_bearer_request, &pg_oauth_bearer_request_type, request);
			VALUE args[] = { proc, PTR2NUM(conn), v_request };

			request->request = data;
			request->request->cleanup = oauth_bearer_request_cleanup;

			ret = rb_rescue(call_auth_data_hook, (VALUE)&args, oauth_bearer_request_hook_cleanup, v_request);

			request->request = NULL;
		}
	}

	return RTEST(ret);
}

/*
 * Document-method: PG.set_auth_data_hook
 *
 * call-seq:
 *   PG.set_auth_data_hook {|data| ... } -> Proc
 *
 * If you pass no arguments, it will reset the handler to the default.
 */
static VALUE
pg_s_set_auth_data_hook(VALUE _self)
{
	PQsetAuthDataHook(gvl_auth_data_hook_proxy); // TODO: Add some safeguards?

	VALUE old_proc = auth_data_hook_get(), proc;

	if (rb_block_given_p()) {
		proc = rb_block_proc();
	} else {
		/* if no block is given, set back to default */
		proc = Qnil;
	}

	auth_data_hook_set(proc);

	return old_proc;
}

void
init_pg_auth_hooks(void)
{
	auth_data_hook_init();

	/* rb_mPG = rb_define_module("PG") */

	rb_define_singleton_method(rb_mPG, "set_auth_data_hook", pg_s_set_auth_data_hook, 0);

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

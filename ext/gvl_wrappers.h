/*
 * gvl_wrappers.h - Wrapper functions for locking/unlocking the Ruby GVL
 *
 * These are some obscure preprocessor directives that allow to generate
 * drop-in replacement wrapper functions in a declarative manner.
 * These wrapper functions ensure that ruby's GVL is released on each
 * function call and reacquired at the end of the call or in callbacks.
 * This way blocking functions calls don't block concurrent ruby threads.
 *
 * The wrapper of each function is prefixed by "gvl_".
 *
 * Use "gcc -E" to retrieve the generated code.
 */

#ifndef __gvl_wrappers_h
#define __gvl_wrappers_h

#if defined(HAVE_RB_THREAD_CALL_WITH_GVL)
extern void *rb_thread_call_with_gvl(void *(*func)(void *), void *data1);
#endif

#if defined(HAVE_RB_THREAD_CALL_WITHOUT_GVL)
extern void *rb_thread_call_without_gvl(void *(*func)(void *), void *data1,
				 rb_unblock_function_t *ubf, void *data2);
#endif

#define DEFINE_PARAM_LIST1(type, name) \
	name,

#define DEFINE_PARAM_LIST2(type, name) \
	p->params.name,

#define DEFINE_PARAM_LIST3(type, name) \
	type name,

#define DEFINE_PARAM_DECL(type, name) \
	type name;

#define DEFINE_GVL_WRAPPER_STRUCT(name, when_non_void, rettype, lastparamtype, lastparamname) \
	struct gvl_wrapper_##name##_params { \
		struct { \
			FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_DECL) \
			lastparamtype lastparamname; \
		} params; \
		when_non_void( rettype retval; ) \
	};

#define DEFINE_GVL_SKELETON(name, when_non_void, rettype, lastparamtype, lastparamname) \
	static void * gvl_##name##_skeleton( void *data ){ \
		struct gvl_wrapper_##name##_params *p = (struct gvl_wrapper_##name##_params*)data; \
		when_non_void( p->retval = ) \
			name( FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST2) p->params.lastparamname ); \
		return NULL; \
	}

#if defined(HAVE_RB_THREAD_CALL_WITHOUT_GVL)
	#define DEFINE_GVL_STUB(name, when_non_void, rettype, lastparamtype, lastparamname) \
		rettype gvl_##name(FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST3) lastparamtype lastparamname){ \
			struct gvl_wrapper_##name##_params params = { \
				{FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST1) lastparamname}, when_non_void((rettype)0) \
			}; \
			rb_thread_call_without_gvl(gvl_##name##_skeleton, &params, RUBY_UBF_IO, 0); \
			when_non_void( return params.retval; ) \
		}
#else
	#define DEFINE_GVL_STUB(name, when_non_void, rettype, lastparamtype, lastparamname) \
		rettype gvl_##name(FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST3) lastparamtype lastparamname){ \
			return name( FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST1) lastparamname ); \
		}
#endif

#define DEFINE_GVL_STUB_DECL(name, when_non_void, rettype, lastparamtype, lastparamname) \
	rettype gvl_##name(FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST3) lastparamtype lastparamname);

#define DEFINE_GVLCB_SKELETON(name, when_non_void, rettype, lastparamtype, lastparamname) \
	static void * gvl_##name##_skeleton( void *data ){ \
		struct gvl_wrapper_##name##_params *p = (struct gvl_wrapper_##name##_params*)data; \
		when_non_void( p->retval = ) \
			name( FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST2) p->params.lastparamname ); \
		return NULL; \
	}

#if defined(HAVE_RB_THREAD_CALL_WITH_GVL)
	#define DEFINE_GVLCB_STUB(name, when_non_void, rettype, lastparamtype, lastparamname) \
		rettype gvl_##name(FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST3) lastparamtype lastparamname){ \
			struct gvl_wrapper_##name##_params params = { \
				{FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST1) lastparamname}, when_non_void((rettype)0) \
			}; \
			rb_thread_call_with_gvl(gvl_##name##_skeleton, &params); \
			when_non_void( return params.retval; ) \
		}
#else
	#define DEFINE_GVLCB_STUB(name, when_non_void, rettype, lastparamtype, lastparamname) \
		rettype gvl_##name(FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST3) lastparamtype lastparamname){ \
			return name( FOR_EACH_PARAM_OF_##name(DEFINE_PARAM_LIST1) lastparamname ); \
		}
#endif

#define GVL_TYPE_VOID(string)
#define GVL_TYPE_NONVOID(string) string


/*
 * Definitions of blocking functions and their parameters
 */

#define FOR_EACH_PARAM_OF_PQexec(param) \
	param(PGconn *, conn)

#define FOR_EACH_PARAM_OF_PQexecParams(param) \
	param(PGconn *, conn) \
	param(const char *, command) \
	param(int, nParams) \
	param(const Oid *, paramTypes) \
	param(const char * const *, paramValues) \
	param(const int *, paramLengths) \
	param(const int *, paramFormats)

#define FOR_EACH_PARAM_OF_PQexecPrepared(param) \
	param(PGconn *, conn) \
	param(const char *, stmtName) \
	param(int, nParams) \
	param(const char * const *, paramValues) \
	param(const int *, paramLengths) \
	param(const int *, paramFormats)

#define FOR_EACH_PARAM_OF_PQprepare(param) \
	param(PGconn *, conn) \
	param(const char *, stmtName) \
	param(const char *, query) \
	param(int, nParams)

#define FOR_EACH_PARAM_OF_PQdescribePrepared(param) \
	param(PGconn *, conn)

#define FOR_EACH_PARAM_OF_PQdescribePortal(param) \
	param(PGconn *, conn)

#define FOR_EACH_PARAM_OF_PQgetResult(param)

#define FOR_EACH_PARAM_OF_PQputCopyData(param) \
	param(PGconn *, conn) \
	param(const char *, buffer)

#define FOR_EACH_PARAM_OF_PQputCopyEnd(param) \
	param(PGconn *, conn)

#define FOR_EACH_PARAM_OF_PQgetCopyData(param) \
	param(PGconn *, conn) \
	param(char **, buffer)

/* function( name, void_or_nonvoid, returntype, lastparamtype, lastparamname ) */
#define FOR_EACH_BLOCKING_FUNCTION(function) \
	function(PQexec, GVL_TYPE_NONVOID, PGresult *, const char *, command) \
	function(PQexecParams, GVL_TYPE_NONVOID, PGresult *, int, resultFormat) \
	function(PQexecPrepared, GVL_TYPE_NONVOID, PGresult *, int, resultFormat) \
	function(PQprepare, GVL_TYPE_NONVOID, PGresult *, const Oid *, paramTypes) \
	function(PQdescribePrepared, GVL_TYPE_NONVOID, PGresult *, const char *, stmtName) \
	function(PQdescribePortal, GVL_TYPE_NONVOID, PGresult *, const char *, portalName) \
	function(PQgetResult, GVL_TYPE_NONVOID, PGresult *, PGconn *, conn) \
	function(PQputCopyData, GVL_TYPE_NONVOID, int, int, nbytes) \
	function(PQputCopyEnd, GVL_TYPE_NONVOID, int, const char *, errormsg) \
	function(PQgetCopyData, GVL_TYPE_NONVOID, int, int, async) \

FOR_EACH_BLOCKING_FUNCTION( DEFINE_GVL_STUB_DECL );


/*
 * Definitions of callback functions and their parameters
 */

#define FOR_EACH_PARAM_OF_notice_processor_proxy(param) \
	param(void *, arg)

#define FOR_EACH_PARAM_OF_notice_receiver_proxy(param) \
	param(void *, arg)

/* function( name, void_or_nonvoid, returntype, lastparamtype, lastparamname ) */
#define FOR_EACH_CALLBACK_FUNCTION(function) \
	function(notice_processor_proxy, GVL_TYPE_VOID, void, const char *, message) \
	function(notice_receiver_proxy, GVL_TYPE_VOID, void, const PGresult *, result) \

FOR_EACH_CALLBACK_FUNCTION( DEFINE_GVL_STUB_DECL );

#endif /* end __gvl_wrappers_h */

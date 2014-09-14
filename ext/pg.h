#ifndef __pg_h
#define __pg_h

#ifdef RUBY_EXTCONF_H
#	include RUBY_EXTCONF_H
#endif

/* System headers */
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#if defined(HAVE_UNISTD_H) && !defined(_WIN32)
#	include <unistd.h>
#endif /* HAVE_UNISTD_H */

/* Ruby headers */
#include "ruby.h"
#ifdef HAVE_RUBY_ST_H
#	include "ruby/st.h"
#elif HAVE_ST_H
#	include "st.h"
#endif

#if defined(HAVE_RUBY_ENCODING_H) && HAVE_RUBY_ENCODING_H
#	include "ruby/encoding.h"
#	define M17N_SUPPORTED
#	define ASSOCIATE_INDEX( obj, index_holder ) rb_enc_associate_index((obj), pg_enc_get_index((index_holder)))
#	ifdef HAVE_RB_ENCDB_ALIAS
		extern int rb_encdb_alias(const char *, const char *);
#		define ENC_ALIAS(name, orig) rb_encdb_alias((name), (orig))
#	elif HAVE_RB_ENC_ALIAS
		extern int rb_enc_alias(const char *, const char *);
#		define ENC_ALIAS(name, orig) rb_enc_alias((name), (orig))
#	else
		extern int rb_enc_alias(const char *alias, const char *orig); /* declaration missing in Ruby 1.9.1 */
#		define ENC_ALIAS(name, orig) rb_enc_alias((name), (orig))
#	endif
#else
#	define ASSOCIATE_INDEX( obj, index_holder ) /* nothing */
#endif

#if RUBY_VM != 1
#	define RUBY_18_COMPAT
#endif

#ifndef RARRAY_LEN
#	define RARRAY_LEN(x) RARRAY((x))->len
#endif /* RARRAY_LEN */

#ifndef RSTRING_LEN
#	define RSTRING_LEN(x) RSTRING((x))->len
#endif /* RSTRING_LEN */

#ifndef RSTRING_PTR
#	define RSTRING_PTR(x) RSTRING((x))->ptr
#endif /* RSTRING_PTR */

#ifndef StringValuePtr
#	define StringValuePtr(x) STR2CSTR(x)
#endif /* StringValuePtr */

#ifdef RUBY_18_COMPAT
#	define rb_io_stdio_file GetWriteFile
#	include "rubyio.h"
#else
#	include "ruby/io.h"
#endif

#ifndef timeradd
#define timeradd(a, b, result) \
	do { \
		(result)->tv_sec = (a)->tv_sec + (b)->tv_sec; \
		(result)->tv_usec = (a)->tv_usec + (b)->tv_usec; \
		if ((result)->tv_usec >= 1000000L) { \
			++(result)->tv_sec; \
			(result)->tv_usec -= 1000000L; \
		} \
	} while (0)
#endif

#ifndef timersub
#define timersub(a, b, result) \
	do { \
		(result)->tv_sec = (a)->tv_sec - (b)->tv_sec; \
		(result)->tv_usec = (a)->tv_usec - (b)->tv_usec; \
		if ((result)->tv_usec < 0) { \
			--(result)->tv_sec; \
			(result)->tv_usec += 1000000L; \
		} \
	} while (0)
#endif

/* PostgreSQL headers */
#include "libpq-fe.h"
#include "libpq/libpq-fs.h"              /* large-object interface */
#include "pg_config_manual.h"

#if defined(_WIN32)
#	include <fcntl.h>
__declspec(dllexport)
typedef long suseconds_t;
#endif

typedef struct pg_coder t_pg_coder;
typedef struct pg_typemap t_typemap;
typedef int (* t_pg_coder_enc_func)(t_pg_coder *, VALUE, char *, VALUE *);
typedef VALUE (* t_pg_coder_dec_func)(t_pg_coder *, char *, int, int, int, int);
typedef VALUE (* t_pg_fit_to_result)(VALUE, VALUE);
typedef VALUE (* t_pg_fit_to_query)(VALUE, VALUE);
typedef VALUE (* t_pg_typecast_result)(VALUE, PGresult *, int, int, t_typemap *);
typedef VALUE (* t_pg_alloc_query_params)(VALUE);

struct pg_coder {
	t_pg_coder_enc_func enc_func;
	t_pg_coder_dec_func dec_func;
	VALUE coder_obj;
	Oid oid;
	int format;
};

typedef struct {
	t_pg_coder comp;
	t_pg_coder *elem;
	int needs_quotation;
	char delimiter;
} t_pg_composite_coder;

struct pg_typemap {
	t_pg_fit_to_result fit_to_result;
	t_pg_fit_to_query fit_to_query;
	t_pg_typecast_result typecast;
	t_pg_alloc_query_params alloc_query_params;
	int encoding_index;
};

struct query_params_data {

	/* filled by caller */
	int with_types;
	VALUE params;
	VALUE param_mapping;

	/* filled by alloc_query_params() */
	Oid *types;
	char **values;
	int *lengths;
	int *formats;
	char *mapping_buf;
	VALUE *param_values;
	VALUE gc_array;
	t_typemap *p_typemap;
};

typedef struct {
	t_typemap typemap;
	int nfields;
	struct pg_tmbc_converter {
		t_pg_coder *cconv;
	} convs[0];
} t_tmbc;


#include "gvl_wrappers.h"

/***************************************************************************
 * Globals
 **************************************************************************/

extern VALUE rb_mPG;
extern VALUE rb_ePGerror;
extern VALUE rb_eServerError;
extern VALUE rb_eUnableToSend;
extern VALUE rb_eConnectionBad;
extern VALUE rb_mPGconstants;
extern VALUE rb_cPGconn;
extern VALUE rb_cPGresult;
extern VALUE rb_hErrors;
extern VALUE rb_cTypeMap;
extern VALUE rb_cPG_Coder;
extern VALUE rb_cPG_SimpleEncoder;
extern VALUE rb_cPG_SimpleDecoder;
extern VALUE rb_cPG_CompositeEncoder;
extern VALUE rb_cPG_CompositeDecoder;


/***************************************************************************
 * MACROS
 **************************************************************************/

#define UNUSED(x) ((void)(x))
#define SINGLETON_ALIAS(klass,new,old) rb_define_alias(rb_singleton_class((klass)),(new),(old))


/***************************************************************************
 * PROTOTYPES
 **************************************************************************/
void Init_pg_ext                                       _(( void ));

void init_pg_connection                                _(( void ));
void init_pg_result                                    _(( void ));
void init_pg_errors                                    _(( void ));
void init_pg_type_map                                  _(( void ));
void init_pg_type_map_by_column                        _(( void ));
void init_pg_type_map_by_oid                           _(( void ));
void init_pg_coder                                     _(( void ));
void init_pg_text_encoder                              _(( void ));
void init_pg_text_decoder                              _(( void ));
void init_pg_binary_encoder                            _(( void ));
void init_pg_binary_decoder                            _(( void ));
VALUE lookup_error_class                               _(( const char * ));
VALUE pg_bin_dec_bytea                                 _(( t_pg_coder*, char *, int, int, int, int ));
VALUE pg_text_dec_string                               _(( t_pg_coder*, char *, int, int, int, int ));
void pg_define_coder                                   _(( const char *, void *, VALUE, VALUE ));
VALUE pg_obj_to_i                                      _(( VALUE ));
VALUE pg_tmbc_allocate                                 _(( void ));
VALUE pg_tmbc_result_value                             _(( VALUE, PGresult *, int, int, t_typemap * ));

PGconn *pg_get_pgconn	                                 _(( VALUE ));

VALUE pg_new_result                                    _(( PGresult *, VALUE ));
PGresult* pgresult_get                                 _(( VALUE ));
VALUE pg_result_check                                  _(( VALUE ));
VALUE pg_result_clear                                  _(( VALUE ));

#ifdef M17N_SUPPORTED
rb_encoding * pg_get_pg_encoding_as_rb_encoding        _(( int ));
rb_encoding * pg_get_pg_encname_as_rb_encoding         _(( const char * ));
const char * pg_get_rb_encoding_as_pg_encoding         _(( rb_encoding * ));
int pg_enc_get_index                                   _(( VALUE ));
rb_encoding *pg_conn_enc_get                           _(( PGconn * ));
#endif /* M17N_SUPPORTED */

void notice_receiver_proxy(void *arg, const PGresult *result);
void notice_processor_proxy(void *arg, const char *message);

#endif /* end __pg_h */

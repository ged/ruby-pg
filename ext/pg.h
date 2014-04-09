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

typedef struct pg_type t_pg_type;
typedef int (* t_pg_type_enc_func)(t_pg_type *, VALUE, char *, VALUE *);
typedef VALUE (* t_pg_type_dec_func)(t_pg_type *, char *, int, int, int, int);

struct pg_type {
	t_pg_type_enc_func enc_func;
	t_pg_type_dec_func dec_func;
	VALUE enc_obj;
	VALUE dec_obj;
	Oid oid;
	int format;
};

typedef struct {
	t_pg_type comp;
	t_pg_type *elem;
	int needs_quotation;
} t_pg_composite_type;

typedef struct {
	int nfields;
	int encoding_index;
	struct pg_colmap_converter {
		t_pg_type *cconv;
	} convs[0];
} t_colmap;


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
extern VALUE rb_cColumnMap;
extern VALUE rb_mPG_Type;
extern VALUE rb_cPG_Type_SimpleType;


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
void init_pg_column_mapping                            _(( void ));
void init_pg_type                                      _(( void ));
void init_pg_type_text_encoder                         _(( void ));
void init_pg_type_text_decoder                         _(( void ));
void init_pg_type_binary_encoder                       _(( void ));
void init_pg_type_binary_decoder                       _(( void ));
VALUE lookup_error_class                               _(( const char * ));
t_colmap *colmap_get_and_check                         _(( VALUE, int ));
VALUE colmap_result_value                              _(( VALUE, PGresult *, int, int, t_colmap * ));
VALUE pg_type_dec_binary_bytea                         _(( t_pg_type*, char *, int, int, int, int ));
VALUE pg_type_dec_text_string                          _(( t_pg_type*, char *, int, int, int, int ));

PGconn *pg_get_pgconn	                               _(( VALUE ));

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

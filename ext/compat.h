
#ifndef __compat_h
#define __compat_h

#include <stdlib.h>

#include "ruby.h"
#include "rubyio.h"
#include "libpq-fe.h"
#include "libpq/libpq-fs.h"              /* large-object interface */


#ifndef HAVE_PQCONNECTIONUSEDPASSWORD
#define POSTGRES_BEFORE_83
#endif

#if RUBY_VERSION_CODE < 180
#define rb_check_string_type(x) rb_check_convert_type(x, T_STRING, "String", "to_str")
#endif /* RUBY_VERSION_CODE < 180 */

#ifndef RARRAY_LEN
#define RARRAY_LEN(x) RARRAY((x))->len
#endif /* RARRAY_LEN */

#ifndef RSTRING_LEN
#define RSTRING_LEN(x) RSTRING((x))->len
#endif /* RSTRING_LEN */

#ifndef RSTRING_PTR
#define RSTRING_PTR(x) RSTRING((x))->ptr
#endif /* RSTRING_PTR */

#ifndef StringValuePtr
#define StringValuePtr(x) STR2CSTR(x)
#endif /* StringValuePtr */

#ifdef POSTGRES_BEFORE_83
#ifndef HAVE_PG_ENCODING_TO_CHAR
#define pg_encoding_to_char(x) "SQL_ASCII"
#else
 /* Some versions ofPostgreSQL prior to 8.3 define
  * pg_encoding_to_char but do not declare it
  * in a header file, so this declaration will
  * eliminate an unecessary warning
  */
extern char* pg_encoding_to_char(int);
#endif /* HAVE_PG_ENCODING_TO_CHAR */
#endif /* POSTGRES_BEFORE_83 */

#ifndef PG_DIAG_INTERNAL_POSITION
#define PG_DIAG_INTERNAL_POSITION 'p'
#endif /* PG_DIAG_INTERNAL_POSITION */

#ifndef PG_DIAG_INTERNAL_QUERY
#define PG_DIAG_INTERNAL_QUERY  'q'
#endif /* PG_DIAG_INTERNAL_QUERY */

#ifndef HAVE_PQFREEMEM
#define PQfreemem(ptr) free(ptr)
#endif /* HAVE_PQFREEMEM */

#ifndef HAVE_PQSETCLIENTENCODING
int PQsetClientEncoding(PGconn *conn, const char *encoding)
#endif /* HAVE_PQSETCLIENTENCODING */

#ifndef HAVE_PQESCAPESTRING
size_t PQescapeString(char *to, const char *from, size_t length);
unsigned char * PQescapeBytea(const unsigned char *bintext, size_t binlen, size_t *bytealen);
unsigned char * PQunescapeBytea(const unsigned char *strtext, size_t *retbuflen);
#endif /* HAVE_PQESCAPESTRING */

#ifndef HAVE_PQESCAPESTRINGCONN
size_t PQescapeStringConn(PGconn *conn, char *to, const char *from, 
	size_t length, int *error);
unsigned char *PQescapeByteaConn(PGconn *conn, const unsigned char *from, 
	size_t from_length, size_t *to_length);
#endif /* HAVE_PQESCAPESTRINGCONN */

#ifndef HAVE_PQPREPARE
PGresult *PQprepare(PGconn *conn, const char *stmtName, const char *query,
	int nParams, const Oid *paramTypes);
#endif /* HAVE_PQPREPARE */

#ifndef HAVE_PQDESCRIBEPREPARED
PGresult * PQdescribePrepared(PGconn *conn, const char *stmtName);
#endif /* HAVE_PQDESCRIBEPREPARED */

#ifndef HAVE_PQDESCRIBEPORTAL
PGresult * PQdescribePortal(PGconn *conn, const char *portalName);
#endif /* HAVE_PQDESCRIBEPORTAL */

#ifndef HAVE_PQCONNECTIONNEEDSPASSWORD
int PQconnectionNeedsPassword(PGconn *conn);
#endif /* HAVE_PQCONNECTIONNEEDSPASSWORD */

#ifndef HAVE_PQCONNECTIONUSEDPASSWORD
int PQconnectionUsedPassword(PGconn *conn);
#endif /* HAVE_PQCONNECTIONUSEDPASSWORD */

#ifndef HAVE_PQISTHREADSAFE
int PQisthreadsafe(void);
#endif /* HAVE_PQISTHREADSAFE */

#ifndef HAVE_LO_TRUNCATE
int lo_truncate(PGconn *conn, int fd, size_t len);
#endif /* HAVE_LO_TRUNCATE */

#ifndef HAVE_LO_CREATE
Oid lo_create(PGconn *conn, Oid lobjId);
#endif /* HAVE_LO_CREATE */

#ifndef HAVE_PQNPARAMS
int PQnparams(const PGresult *res);
#endif /* HAVE_PQNPARAMS */

#ifndef HAVE_PQPARAMTYPE
Oid PQparamtype(const PGresult *res, int param_number);
#endif /* HAVE_PQPARAMTYPE */

#ifndef HAVE_PQSERVERVERSION
int PQserverVersion(const PGconn* conn);
#endif /* HAVE_PQSERVERVERSION */

#ifndef HAVE_PQEXECPARAMS
PGresult *PQexecParams(PGconn *conn, const char *command, int nParams, 
	const Oid *paramTypes, const char * const * paramValues, const int *paramLengths, 
	const int *paramFormats, int resultFormat);
PGresult *PQexecParams_compat(PGconn *conn, VALUE command, VALUE values);
#endif /* HAVE_PQEXECPARAMS */

#ifndef HAVE_PQSENDDESCRIBEPREPARED
int PQsendDescribePrepared(PGconn *conn, const char *stmtName);
#endif /* HAVE_PQSENDDESCRIBEPREPARED */

#ifndef HAVE_PQSENDDESCRIBEPORTAL
int PQsendDescribePortal(PGconn *conn, const char *portalName);
#endif /* HAVE_PQSENDDESCRIBEPORTAL */

#ifndef HAVE_PQSENDPREPARE
int PQsendPrepare(PGconn *conn, const char *stmtName, const char *query,
	int nParams, const Oid *paramTypes);
#endif /* HAVE_PQSENDPREPARE */

#ifndef HAVE_PQENCRYPTPASSWORD
char *PQencryptPassword(const char *passwd, const char *user);
#endif /* HAVE_PQENCRYPTPASSWORD */

#endif /* __compat_h */

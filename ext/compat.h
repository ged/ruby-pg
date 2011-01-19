
#ifndef __compat_h
#define __compat_h

#include <stdlib.h>

#ifdef RUBY_EXTCONF_H
#include RUBY_EXTCONF_H
#endif

#include "libpq-fe.h"
#include "libpq/libpq-fs.h"              /* large-object interface */

#include "ruby.h"

/* pg_config.h does not exist in older versions of
 * PostgreSQL, so I can't effectively use PG_VERSION_NUM
 * Instead, I create some #defines to help organization.
 */
#ifndef HAVE_PQCONNECTIONUSEDPASSWORD
#define PG_BEFORE_080300
#endif

#ifndef HAVE_PQISTHREADSAFE
#define PG_BEFORE_080200
#endif

#ifndef HAVE_LO_CREATE
#define PG_BEFORE_080100
#endif

#ifndef HAVE_PQPREPARE
#define PG_BEFORE_080000
#endif

#ifndef HAVE_PQEXECPARAMS
#define PG_BEFORE_070400
#endif

#ifndef HAVE_PQESCAPESTRINGCONN
#define PG_BEFORE_070300
#error PostgreSQL client version too old, requires 7.3 or later.
#endif

/* This is necessary because NAMEDATALEN is defined in 
 * pg_config_manual.h in 8.3, and that include file doesn't
 * exist before 7.4
 */
#ifndef PG_BEFORE_070400
#include "pg_config_manual.h"
#endif

#ifndef PG_DIAG_INTERNAL_POSITION
#define PG_DIAG_INTERNAL_POSITION 'p'
#endif /* PG_DIAG_INTERNAL_POSITION */

#ifndef PG_DIAG_INTERNAL_QUERY
#define PG_DIAG_INTERNAL_QUERY  'q'
#endif /* PG_DIAG_INTERNAL_QUERY */

#ifdef PG_BEFORE_080300

#ifndef HAVE_PG_ENCODING_TO_CHAR
#define pg_encoding_to_char(x) "SQL_ASCII"
#else
 /* Some versions ofPostgreSQL prior to 8.3 define pg_encoding_to_char
  * but do not declare it in a header file, so this declaration will
  * eliminate an unecessary warning
  */
extern char* pg_encoding_to_char(int);
#endif /* HAVE_PG_ENCODING_TO_CHAR */

int PQconnectionNeedsPassword(PGconn *conn);
int PQconnectionUsedPassword(PGconn *conn);
int lo_truncate(PGconn *conn, int fd, size_t len);

#endif /* PG_BEFORE_080300 */

#ifdef PG_BEFORE_080200
int PQisthreadsafe(void);
int PQnparams(const PGresult *res);
Oid PQparamtype(const PGresult *res, int param_number);
PGresult * PQdescribePrepared(PGconn *conn, const char *stmtName);
PGresult * PQdescribePortal(PGconn *conn, const char *portalName);
int PQsendDescribePrepared(PGconn *conn, const char *stmtName);
int PQsendDescribePortal(PGconn *conn, const char *portalName);
char *PQencryptPassword(const char *passwd, const char *user);
#endif /* PG_BEFORE_080200 */

#ifdef PG_BEFORE_080100
Oid lo_create(PGconn *conn, Oid lobjId);
#endif /* PG_BEFORE_080100 */

#ifdef PG_BEFORE_080000
PGresult *PQprepare(PGconn *conn, const char *stmtName, const char *query,
	int nParams, const Oid *paramTypes);
int PQsendPrepare(PGconn *conn, const char *stmtName, const char *query,
	int nParams, const Oid *paramTypes);
int PQserverVersion(const PGconn* conn);
#endif /* PG_BEFORE_080000 */

#ifdef PG_BEFORE_070400

#define PG_DIAG_SEVERITY        'S'
#define PG_DIAG_SQLSTATE        'C'
#define PG_DIAG_MESSAGE_PRIMARY 'M'
#define PG_DIAG_MESSAGE_DETAIL  'D'
#define PG_DIAG_MESSAGE_HINT    'H'
#define PG_DIAG_STATEMENT_POSITION 'P'
#define PG_DIAG_CONTEXT         'W'
#define PG_DIAG_SOURCE_FILE     'F'
#define PG_DIAG_SOURCE_LINE     'L'
#define PG_DIAG_SOURCE_FUNCTION 'R'

#define PQfreemem(ptr) free(ptr)
#define PGNOTIFY_EXTRA(notify) ""

/* CONNECTION_SSL_STARTUP was added to an enum type
 * after 7.3. For 7.3 in order to compile, we just need
 * it to evaluate to something that is not present in that
 * enum.
 */
#define CONNECTION_SSL_STARTUP 1000000

typedef void (*PQnoticeReceiver) (void *arg, const PGresult *res);

typedef enum
{
	PQERRORS_TERSE,		/* single-line error messages */
	PQERRORS_DEFAULT,	/* recommended style */
	PQERRORS_VERBOSE	/* all the facts, ma'am */
} PGVerbosity;

typedef enum
{
	PQTRANS_IDLE,		/* connection idle */
	PQTRANS_ACTIVE,		/* command in progress */
	PQTRANS_INTRANS,	/* idle, within transaction block */
	PQTRANS_INERROR,	/* idle, within failed transaction */
	PQTRANS_UNKNOWN		/* cannot determine status */
} PGTransactionStatusType;

PGresult *PQexecParams(PGconn *conn, const char *command, int nParams, 
	const Oid *paramTypes, const char * const * paramValues, const int *paramLengths, 
	const int *paramFormats, int resultFormat);
PGTransactionStatusType PQtransactionStatus(const PGconn *conn);
char *PQparameterStatus(const PGconn *conn, const char *paramName);
int PQprotocolVersion(const PGconn *conn);
PGresult *PQexecPrepared(PGconn *conn, const char *stmtName, int nParams, 
	const char * const *ParamValues, const int *paramLengths, const int *paramFormats,
	int resultFormat);
int PQsendQueryParams(PGconn *conn, const char *command, int nParams,
	const Oid *paramTypes, const char * const * paramValues, const int *paramLengths, 
	const int *paramFormats, int resultFormat);
int PQsendQueryPrepared(PGconn *conn, const char *stmtName, int nParams, 
	const char * const *ParamValues, const int *paramLengths, const int *paramFormats,
	int resultFormat);
int PQputCopyData(PGconn *conn, const char *buffer, int nbytes);
int PQputCopyEnd(PGconn *conn, const char *errormsg);
int PQgetCopyData(PGconn *conn, char **buffer, int async);
PGVerbosity PQsetErrorVerbosity(PGconn *conn, PGVerbosity verbosity);
Oid PQftable(const PGresult *res, int column_number);
int PQftablecol(const PGresult *res, int column_number);
int PQfformat(const PGresult *res, int column_number);
char *PQresultErrorField(const PGresult *res, int fieldcode);
PQnoticeReceiver PQsetNoticeReceiver(PGconn *conn, PQnoticeReceiver proc, void *arg);

#else
#define PGNOTIFY_EXTRA(notify) ((notify)->extra)
#endif /* PG_BEFORE_070400 */

#ifdef PG_BEFORE_070300
#error unsupported postgresql version, requires 7.3 or later.
int PQsetClientEncoding(PGconn *conn, const char *encoding)
size_t PQescapeString(char *to, const char *from, size_t length);
unsigned char * PQescapeBytea(const unsigned char *bintext, size_t binlen, size_t *bytealen);
unsigned char * PQunescapeBytea(const unsigned char *strtext, size_t *retbuflen);
size_t PQescapeStringConn(PGconn *conn, char *to, const char *from, 
	size_t length, int *error);
unsigned char *PQescapeByteaConn(PGconn *conn, const unsigned char *from, 
	size_t from_length, size_t *to_length);
#endif /* PG_BEFORE_070300 */

#endif /* __compat_h */

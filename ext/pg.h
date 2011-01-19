#ifndef PG_H_C98VS4AD
#define PG_H_C98VS4AD

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#ifdef RUBY_EXTCONF_H
#include RUBY_EXTCONF_H
#endif

#ifdef HAVE_UNISTD_H
#	include <unistd.h>
#endif /* HAVE_UNISTD_H */

#include "ruby.h"
#include "libpq-fe.h"
#include "libpq/libpq-fs.h"              /* large-object interface */
#include "compat.h"

#if RUBY_VM != 1
#define RUBY_18_COMPAT
#endif

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

#ifdef RUBY_18_COMPAT
#define rb_io_stdio_file GetWriteFile
#include "rubyio.h"
#else
#include "ruby/io.h"
#endif

#if defined(_WIN32)
__declspec(dllexport)
#endif
void Init_pg_ext(void);

#endif /* end of include guard: PG_H_C98VS4AD */

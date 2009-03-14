#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#include "ruby.h"
#include "rubyio.h"
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
#endif

#if defined(_WIN32)
__declspec(dllexport)
#endif
void Init_pg(void);


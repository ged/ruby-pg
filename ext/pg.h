#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

#include "ruby.h"
#include "rubyio.h"
#include "libpq-fe.h"
#include "libpq/libpq-fs.h"              /* large-object interface */
#include "pg_config_manual.h"

#include "compat.h"

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

void Init_pg(void);


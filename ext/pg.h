#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#include "ruby.h"
#include "rubyio.h"
#include "libpq-fe.h"
#include "libpq/libpq-fs.h"              /* large-object interface */

#include "compat.h"

void Init_pg(void);


MODULES = dummy_validator
PGFILEDESC = "dummy_validator - dummy OAuth validator"

OBJS = $(WIN32RES)

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

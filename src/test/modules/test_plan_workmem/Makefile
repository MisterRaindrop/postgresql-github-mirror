# src/test/modules/test_plan_workmem/Makefile

PGFILEDESC = "test_plan_workmem - test the per-node working-memory limit"

MODULE_big = test_plan_workmem
OBJS = \
	$(WIN32RES) \
	test_plan_workmem.o

REGRESS = test_plan_workmem

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = src/test/modules/test_plan_workmem
top_builddir = ../../../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

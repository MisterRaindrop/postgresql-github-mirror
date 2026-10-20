# Copyright (c) 2026, PostgreSQL Global Development Group
PGFILEDESC = "test_fopen - Windows libpgport fopen tests"
PGAPPICON = win32
PROGRAM = test_fopen
OBJS = $(WIN32RES) test_fopen.o
NO_INSTALLCHECK = 1
TAP_TESTS = 1

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = src/test/modules/test_pgport
top_builddir = ../../../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

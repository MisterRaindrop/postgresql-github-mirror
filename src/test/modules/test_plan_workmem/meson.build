# Copyright (c) 2026, PostgreSQL Global Development Group

test_plan_workmem_sources = files(
  'test_plan_workmem.c',
)

if host_system == 'windows'
  test_plan_workmem_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'test_plan_workmem',
    '--FILEDESC', 'test_plan_workmem - test the per-node working-memory limit',])
endif

test_plan_workmem = shared_module('test_plan_workmem',
  test_plan_workmem_sources,
  kwargs: pg_test_mod_args,
)
test_install_libs += test_plan_workmem

tests += {
  'name': 'test_plan_workmem',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'regress': {
    'sql': [
      'test_plan_workmem',
    ],
  },
}

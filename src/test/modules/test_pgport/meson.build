# Copyright (c) 2026, PostgreSQL Global Development Group

# Windows port API tests, without starting a server.
if host_system != 'windows'
  subdir_done()
endif

test_fopen = executable('test_fopen',
  files('test_fopen.c'),
  dependencies: [frontend_code],
  kwargs: default_bin_args + {'install': false},
)

tests += {
  'name': 'test_pgport',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'tap': {
    'tests': ['t/001_fopen.pl'],
    'deps': [test_fopen],
  },
}

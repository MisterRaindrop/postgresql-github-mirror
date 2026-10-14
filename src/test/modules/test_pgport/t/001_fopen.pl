# Copyright (c) 2026, PostgreSQL Global Development Group
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Utils;
use Test::More;
use IPC::Run qw(run);

plan skip_all => 'Windows fopen access and translation modes'
  unless $windows_os;

my $fixture_dir = PostgreSQL::Test::Utils::tempdir_short;
my $fixture = "$fixture_dir/fopen owned fixture.dat";
my ($stdout, $stderr) = ('', '');
my $ok = run [ 'test_fopen', $fixture ], '>' => \$stdout, '2>' => \$stderr;
ok($ok, 'libpgport implements Windows fopen mode semantics');
like(
	$stdout,
	qr/cases=48 failures=0/,
	'all update and non-update controls pass');
is($stderr, '', 'no fixture or stream errors');
ok(!-e $fixture, 'fixture is removed');
diag($stdout) unless $ok;
done_testing();

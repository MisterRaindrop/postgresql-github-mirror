# Copyright (c) 2026, PostgreSQL Global Development Group

# Test that pg_upgrade detects foreign keys with incompatible collations on
# the key columns, where at least one of the collations is nondeterministic.
# Those were rejected starting with PG 18, but clusters upgraded from older
# versions could still contain them, and without the check the failure would
# happen only in the middle of the schema restore.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Can be changed to test the other modes.
my $mode = $ENV{PG_TEST_PG_UPGRADE_MODE} || '--copy';

# Nondeterministic collations are only supported by builds with ICU.
plan skip_all => 'ICU not supported by this build'
  unless defined($ENV{with_icu}) && $ENV{with_icu} eq 'yes';

# Initialize old and new clusters.
my $old = PostgreSQL::Test::Cluster->new('old');
my $new = PostgreSQL::Test::Cluster->new('new');
$old->init();
$new->init();

$old->start;

$old->safe_psql('postgres', qq{
CREATE COLLATION ci_nd (provider = icu, locale = 'und-u-ks-level2',
                        deterministic = false);
CREATE TABLE fk_p (k text COLLATE ci_nd PRIMARY KEY);
CREATE TABLE fk_c (k text COLLATE ci_nd REFERENCES fk_p (k));
});

# An FK with mismatched nondeterministic collations cannot be created with
# regular commands anymore, so mimic a pre-18 cluster by directly pointing
# the referencing column at a different (deterministic) collation in the
# catalogs, in the same shape pg_upgrade would see after an upgrade from
# an old cluster.
$old->safe_psql('postgres', qq{
UPDATE pg_attribute a
SET attcollation = 'pg_catalog."default"'::regcollation
WHERE a.attrelid = 'public.fk_c'::regclass AND a.attname = 'k';
});

$old->stop;

# In a VPATH build, we'll be started in the source directory, but we want
# to run pg_upgrade in the build directory so that any files generated
# finish in it, like delete_old_cluster.{sh,bat}.
chdir ${PostgreSQL::Test::Utils::tmp_check};

# The check should detect the mismatch and fail.
command_checks_all(
	[
		'pg_upgrade', '--no-sync', '--check',
		'--old-datadir' => $old->data_dir,
		'--new-datadir' => $new->data_dir,
		'--old-bindir' => $old->config_data('--bindir'),
		'--new-bindir' => $new->config_data('--bindir'),
		'--socketdir' => $new->host,
		'--old-port' => $old->port,
		'--new-port' => $new->port,
		$mode
	],
	1,
	[qr/Checking for foreign keys with incompatible collations/,
	 qr/foreign key constraints with.*different collations on the referencing/s],
	[],
	'run of pg_upgrade --check with FK collation mismatch');

# After removing the offending constraint, the upgrade should succeed.
$old->start;
$old->safe_psql('postgres', 'ALTER TABLE fk_c DROP CONSTRAINT fk_c_k_fkey');
$old->stop;

command_ok(
	[
		'pg_upgrade', '--no-sync',
		'--old-datadir' => $old->data_dir,
		'--new-datadir' => $new->data_dir,
		'--old-bindir' => $old->config_data('--bindir'),
		'--new-bindir' => $new->config_data('--bindir'),
		'--socketdir' => $new->host,
		'--old-port' => $old->port,
		'--new-port' => $new->port,
		$mode
	],
	'run of pg_upgrade after dropping the offending FK');

done_testing();

# Copyright (c) 2026, PostgreSQL Global Development Group

# Test cleanup of permanent relation files created by transactions that are
# still in progress when the server crashes.
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('relation_create_manifests');
$node->init(allows_streaming => 1);
$node->append_conf('postgresql.conf', 'max_prepared_transactions = 10');
$node->start();

my $manifest_dir = $node->data_dir . '/pg_relcreate';

sub manifest_count
{
	my ($cluster) = @_;
	my $dir = $cluster->data_dir . '/pg_relcreate';

	return scalar(grep { $_ ne '.' && $_ ne '..' } slurp_dir($dir));
}

$node->safe_psql('postgres', 'CREATE TABLE committed_relation (a int)');
is(manifest_count($node), 0,
	'committed relation leaves no creation manifest');

my $rollback_session = $node->background_psql('postgres');
$rollback_session->query_safe('BEGIN');
$rollback_session->query_safe(
	'CREATE TABLE rolled_back_relation_1 (a int); '
	  . 'CREATE TABLE rolled_back_relation_2 (a int)');
is(manifest_count($node), 1,
	'two relations in a transaction share one manifest before rollback');
$rollback_session->query_safe('ROLLBACK');
is(manifest_count($node), 0,
	'ordinary rollback removes relation creation manifest');
is($node->safe_psql('postgres',
	q{SELECT to_regclass('rolled_back_relation_1') IS NULL AND
to_regclass('rolled_back_relation_2') IS NULL}),
	't', 'ordinarily aborted relations are absent from the catalog');

my $subxact_session = $node->background_psql('postgres');
$subxact_session->query_safe('BEGIN');
$subxact_session->query_safe('CREATE TABLE top_relation (a int)');
$subxact_session->query_safe('SAVEPOINT create_relation');
$subxact_session->query_safe('CREATE TABLE sub_relation (a int)');
is(manifest_count($node), 2,
	'top-level and subtransaction relation creations use separate manifests');
$subxact_session->query_safe('RELEASE SAVEPOINT create_relation');
$subxact_session->query_safe('ROLLBACK');
is(manifest_count($node), 0,
	'top-level rollback removes subtransaction creation manifests');

my $session = $node->background_psql('postgres');
$session->query_safe('BEGIN');
my @relation_paths = split /\n/, $session->query_safe(
	'CREATE TABLE crash_aborted_relation_1 (a int); '
	  . 'CREATE TABLE crash_aborted_relation_2 (a int); '
	  . q{SELECT pg_relation_filepath('crash_aborted_relation_1') UNION ALL }
	  . q{SELECT pg_relation_filepath('crash_aborted_relation_2')});

is(scalar(grep { !-f $node->data_dir . '/' . $_ } @relation_paths), 0,
	'uncommitted relation files exist before crash');
is(manifest_count($node), 1,
	'two relations created by one transaction share one manifest');

# Move the redo pointer past the creation record.  Recovery therefore needs
# the persistent manifest; replay-local tracking of the create record is not
# sufficient.
$node->safe_psql('postgres', 'CHECKPOINT');
$node->stop('immediate');
$node->start();

is($node->safe_psql('postgres',
	q{SELECT to_regclass('crash_aborted_relation_1') IS NULL AND
to_regclass('crash_aborted_relation_2') IS NULL}),
	't', 'crash-aborted relations are absent from the catalog');
is(scalar(grep { -e $node->data_dir . '/' . $_ } @relation_paths), 0,
	'crash-aborted relation files are removed during recovery');
is(manifest_count($node), 0, 'processed creation manifest is removed');

my $truncated_session = $node->background_psql('postgres');
$truncated_session->query_safe('BEGIN');
my $truncated_relation_path = $truncated_session->query_safe(
	q{CREATE TABLE truncated_manifest_relation (a int);
SELECT pg_relation_filepath('truncated_manifest_relation');});
is(manifest_count($node), 1,
	'relation creation writes a manifest to truncate');
$node->safe_psql('postgres', 'CHECKPOINT');
$node->stop('immediate');

my @manifest_names =
  grep { $_ ne '.' && $_ ne '..' } slurp_dir($manifest_dir);
is(scalar(@manifest_names), 1, 'found manifest to truncate');
my $truncated_manifest = $manifest_dir . '/' . $manifest_names[0];
open(my $manifest_fh, '>>', $truncated_manifest)
  or die "could not open $truncated_manifest: $!";
binmode($manifest_fh);
print {$manifest_fh} "\0";
close($manifest_fh) or die "could not close $truncated_manifest: $!";

ok(!$node->start(fail_ok => 1),
	'startup rejects a truncated relation creation manifest');
truncate($truncated_manifest, (-s $truncated_manifest) - 1)
  or die "could not repair $truncated_manifest: $!";
$node->start();
ok(!-e $node->data_dir . '/' . $truncated_relation_path,
	'repaired manifest removes the crash-aborted relation file');
is(manifest_count($node), 0, 'repaired manifest is removed');

my $prepared_path = $node->safe_psql(
	'postgres',
	q{BEGIN;
CREATE TABLE prepared_relation (a int);
SELECT pg_relation_filepath('prepared_relation');
PREPARE TRANSACTION 'relation_create_marker';});
ok(-f $node->data_dir . '/' . $prepared_path,
	'prepared relation file exists');
is(manifest_count($node), 1,
	'prepared relation retains its creation manifest');

$node->stop('immediate');
$node->start();

ok(-f $node->data_dir . '/' . $prepared_path,
	'prepared relation file survives recovery');
is(manifest_count($node), 1,
	'recovery retains prepared relation manifest');
$node->safe_psql('postgres',
	q{COMMIT PREPARED 'relation_create_marker'});
is($node->safe_psql('postgres',
	q{SELECT to_regclass('prepared_relation') IS NOT NULL}),
	't', 'committed prepared relation is visible');
is(manifest_count($node), 0,
	'commit prepared removes relation manifest');

$node->safe_psql(
	'postgres',
	q{BEGIN;
CREATE TABLE aborted_prepared_relation (a int);
PREPARE TRANSACTION 'relation_create_manifest_abort';});
is(manifest_count($node), 1,
	'prepared transaction to abort retains its manifest');
$node->safe_psql('postgres',
	q{ROLLBACK PREPARED 'relation_create_manifest_abort'});
is(manifest_count($node), 0,
	'rollback prepared removes relation manifest');

$node->backup('manifest_backup');
my $standby = PostgreSQL::Test::Cluster->new('relation_create_standby');
$standby->init_from_backup($node, 'manifest_backup', has_streaming => 1);
$standby->start();

my $commit_session = $node->background_psql('postgres');
$commit_session->query_safe('BEGIN');
$commit_session->query_safe(
	'CREATE TABLE standby_committed_relation_1 (a int); '
	  . 'CREATE TABLE standby_committed_relation_2 (a int)');
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');
$node->wait_for_catchup($standby);
is(manifest_count($standby), 1,
	'standby uses one manifest for two relations from one transaction');
$commit_session->query_safe('COMMIT');
$node->wait_for_catchup($standby);
is(manifest_count($standby), 0,
	'commit replay removes standby relation creation manifest');

my $abort_session = $node->background_psql('postgres');
$abort_session->query_safe('BEGIN');
$abort_session->query_safe('CREATE TABLE standby_aborted_relation (a int)');
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');
$node->wait_for_catchup($standby);
is(manifest_count($standby), 1,
	'standby retains manifest for an in-progress transaction');
$abort_session->query_safe('ROLLBACK');
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');
$node->wait_for_catchup($standby);
is(manifest_count($standby), 0,
	'abort replay removes standby relation creation manifest');

$standby->stop();
$node->stop();
done_testing();

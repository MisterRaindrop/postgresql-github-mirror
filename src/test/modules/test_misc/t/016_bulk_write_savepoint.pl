# Copyright (c) 2026, PostgreSQL Global Development Group

# Check that a bulk write that fails in smgr_bulk_finish(), with the
# error caught by a savepoint, does not make checkpoints wait until the
# top-level transaction ends.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

# The injection point is on the path for WAL-logged bulk writes, so
# wal_level must be higher than minimal.
my $node = PostgreSQL::Test::Cluster->new('node');
$node->init(allows_streaming => 1);
$node->start;

if (!$node->check_extension('injection_points'))
{
	plan skip_all => 'Extension injection_points not installed';
}

$node->safe_psql(
	'postgres', q(
	CREATE EXTENSION injection_points;
	CREATE TABLE tab (a int);
	INSERT INTO tab SELECT generate_series(1, 1000);
));

# Make CREATE INDEX fail in smgr_bulk_finish(), inside a savepoint.
my $psql = $node->background_psql('postgres', on_error_stop => 0);
$psql->query_safe(
	q(SELECT injection_points_set_local();
	  SELECT injection_points_attach('bulk-write-before-registersync', 'error');
	  BEGIN;
	  SAVEPOINT sp;));
$psql->query('CREATE INDEX tab_a_idx ON tab (a)');
like(
	$psql->{stderr},
	qr/error triggered for injection point bulk-write-before-registersync/,
	'CREATE INDEX fails in smgr_bulk_finish()');
$psql->{stderr} = '';
$psql->query_safe(
	q(ROLLBACK TO sp;
	  SELECT injection_points_detach('bulk-write-before-registersync');));

# The transaction is still open.  A checkpoint must not wait for it.
my $timed_out = 0;
$node->psql(
	'postgres', 'CHECKPOINT',
	timeout => $PostgreSQL::Test::Utils::timeout_default,
	timed_out => \$timed_out);
ok(!$timed_out, 'CHECKPOINT completes after ROLLBACK TO SAVEPOINT');

# Another bulk write in the same transaction works.
$psql->query_safe(
	q(CREATE INDEX tab_a_idx ON tab (a);
	  COMMIT;));
is( $node->safe_psql(
		'postgres', "SELECT count(*) FROM pg_index WHERE indexrelid = 'tab_a_idx'::regclass"),
	'1',
	'second CREATE INDEX in the same transaction succeeds');

$psql->quit;
done_testing();

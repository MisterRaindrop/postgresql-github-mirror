# Copyright (c) 2026, PostgreSQL Global Development Group

# Test that a checkpoint cannot start between the WAL record of a new
# multixact and the update of the offsets and members SLRUs.  If it could,
# the checkpoint might flush the SLRU pages before they hold the new
# multixact, and crash recovery would begin after the WAL record, losing
# the multixact's members.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;

use Test::More;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'test_slru,injection_points'");
$node->start;
$node->safe_psql('postgres', q(CREATE EXTENSION injection_points));
$node->safe_psql('postgres', q(CREATE EXTENSION test_slru));

# The multixact created below gets the next multixact ID.
$node->safe_psql('postgres', q(CHECKPOINT));
my $multi = $node->safe_psql('postgres',
	q(SELECT next_multixact_id FROM pg_control_checkpoint()));
my $ckpt_lsn = $node->safe_psql('postgres',
	q(SELECT checkpoint_lsn FROM pg_control_checkpoint()));

# Create a multixact, and stop after its WAL record has been inserted.
my $creator = $node->background_psql('postgres');
$creator->query_safe(
	q(SELECT injection_points_set_local();
SELECT injection_points_attach('multixact-create-after-wal', 'wait');));
$creator->query_until(
	qr/creating multi/, q(
\echo creating multi
SELECT test_create_multixact();
));
$node->wait_for_event('client backend', 'multixact-create-after-wal');

# Request a checkpoint.  Its redo pointer is after the multixact's WAL
# record.  The checkpoint must wait for the creator to finish.
my $checkpoint = $node->background_psql('postgres');
$checkpoint->query_until(
	qr/starting checkpoint/, q(
\echo starting checkpoint
CHECKPOINT;
));

# Wait until the checkpoint has either completed or is waiting for the
# creator.
$node->poll_query_until(
	'postgres', qq(
SELECT checkpoint_lsn <> '$ckpt_lsn' FROM pg_control_checkpoint()
UNION ALL
SELECT true FROM pg_stat_activity
  WHERE backend_type = 'checkpointer'
  AND wait_event = 'CheckpointDelayStart'
ORDER BY 1 DESC LIMIT 1))
  or die "timed out waiting for the checkpoint";

$node->safe_psql('postgres',
	q(SELECT injection_points_wakeup('multixact-create-after-wal')));
$creator->quit;
$checkpoint->quit;

# Crash, and check that the members of the multixact survived.
$node->stop('immediate');
$node->start;

my ($ret, $stdout, $stderr) = $node->psql('postgres',
	qq(SELECT count(*) FILTER (WHERE xid <> '0') FROM pg_get_multixact_members('$multi')));
is($ret, 0, 'multixact members can be read after crash');
is($stdout, '2', 'multixact members are valid after crash');

done_testing();

# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Reproduce a race between CheckPointTwoPhase() changing ondisk/LSNs and
# LookupGXact() reading those fields without syncing.
#
# LookupGXact() is called by the logical replication apply worker when it
# receives ROLLBACK PREPARED, to check whether the transaction was prepared on
# the subscriber.  It holds TwoPhaseStateLock in shared mode, which does not
# exclude the checkpointer.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $node_publisher =
  PostgreSQL::Test::Cluster->new('twophase_lookup_publisher');
$node_publisher->init(allows_streaming => 'logical');
$node_publisher->append_conf('postgresql.conf', q{
	max_prepared_transactions = 10
});
$node_publisher->start;

my $node_subscriber =
  PostgreSQL::Test::Cluster->new('twophase_lookup_subscriber');
$node_subscriber->init;
$node_subscriber->append_conf('postgresql.conf', q{
	max_prepared_transactions = 10
	log_checkpoints = on
});
$node_subscriber->start;

if (!$node_subscriber->check_extension('injection_points'))
{
	plan skip_all => 'Extension injection_points not installed';
}

$node_subscriber->safe_psql('postgres', q{CREATE EXTENSION injection_points});

$node_publisher->safe_psql('postgres', 'CREATE TABLE tab (a int PRIMARY KEY)');
$node_subscriber->safe_psql('postgres', 'CREATE TABLE tab (a int PRIMARY KEY)');
$node_publisher->safe_psql('postgres',
	'CREATE PUBLICATION tap_pub FOR TABLE tab');

my $publisher_connstr = $node_publisher->connstr . ' dbname=postgres';
my $appname = 'tap_sub';
$node_subscriber->safe_psql('postgres',
	"CREATE SUBSCRIPTION tap_sub CONNECTION '$publisher_connstr application_name=$appname' PUBLICATION tap_pub WITH (two_phase = on)"
);

# Wait for the initial table sync and for two_phase to be enabled, so that
# prepared transactions are replicated as such.
$node_publisher->wait_for_catchup($appname);
$node_subscriber->wait_for_subscription_sync($node_publisher, $appname);
$node_subscriber->poll_query_until('postgres',
	"SELECT count(1) = 0 FROM pg_subscription WHERE subtwophasestate NOT IN ('e')"
) or die "Timed out while waiting for subscriber to enable twophase";

# The apply worker stops in LookupGXact() once it has seen ondisk=false.
$node_subscriber->safe_psql(
	'postgres',
	q{SELECT injection_points_attach('twophase-lookup-after-ondisk-read',
									 'wait')});

# The apply worker prepares the transaction on the subscriber.
$node_publisher->safe_psql('postgres', q{
	BEGIN;
	INSERT INTO tab VALUES (1);
	PREPARE TRANSACTION 'twophase_lookup_race_gid';
});
$node_publisher->wait_for_catchup($appname);
is( $node_subscriber->safe_psql(
		'postgres', 'SELECT count(*) FROM pg_prepared_xacts'),
	'1',
	'transaction is prepared on subscriber');

# ROLLBACK PREPARED makes the apply worker call LookupGXact().
$node_publisher->safe_psql('postgres',
	q{ROLLBACK PREPARED 'twophase_lookup_race_gid'});
$node_subscriber->wait_for_event('logical replication apply worker',
	'twophase-lookup-after-ondisk-read');

# The checkpoint now sets ondisk=true and stops before clearing the LSNs.
# Attach this point only now, so that no earlier checkpoint can hit it.
$node_subscriber->safe_psql(
	'postgres',
	q{SELECT injection_points_attach('twophase-checkpoint-after-ondisk-set',
									 'wait')});
my $checkpoint = $node_subscriber->background_psql('postgres');
$checkpoint->query_until(
	qr/checkpoint_started/, q{
	\echo checkpoint_started
	CHECKPOINT;
	\echo checkpoint_finished
});
$node_subscriber->wait_for_event('checkpointer',
	'twophase-checkpoint-after-ondisk-set');

# Finish the checkpoint first, so prepare_start_lsn is invalidated.  Then
# resume the apply worker, which still has the earlier ondisk=false value.
$node_subscriber->safe_psql('postgres',
	q{SELECT injection_points_wakeup('twophase-checkpoint-after-ondisk-set')});
$checkpoint->query_until(qr/checkpoint_finished/, '');
$checkpoint->quit;

# Take the log offset BEFORE resuming the apply worker, so that a message
# logged right after the wakeup cannot be missed.
my $log_offset = -s $node_subscriber->logfile;

$node_subscriber->safe_psql('postgres',
	q{SELECT injection_points_wakeup('twophase-lookup-after-ondisk-read')});

# Either the apply worker finds the prepared transaction and rolls it back, or
# it hits the assertion (or a WAL read error).  The TAP harness runs servers
# with restart_after_crash = off, so after a crash the subscriber stays down
# and the publisher never catches up.  Poll for whichever outcome comes first
# instead of waiting for the catchup.
my $outcome = 'timeout';
my $detail = '';
my $max_iters = 10 * $PostgreSQL::Test::Utils::timeout_default;

for (my $i = 0; $i < $max_iters; $i++)
{
	my $log = slurp_file($node_subscriber->logfile, $log_offset);
	if ($log =~
		/(TRAP: failed Assert[^\n]*|could not read two-phase state from WAL at 0\/0[^\n]*)/
	  )
	{
		$outcome = 'broken';
		$detail = $1;
		last;
	}

	my ($ret, $count) = $node_subscriber->psql('postgres',
		'SELECT count(*) FROM pg_prepared_xacts');
	if ($ret == 0 && $count eq '0')
	{
		$outcome = 'rolled_back';
		last;
	}

	usleep(100_000);
}

is($outcome, 'rolled_back',
	'apply worker handles ROLLBACK PREPARED despite a concurrent checkpoint'
) or diag("outcome: $outcome; server log: $detail");

# The subscriber is already down if the apply worker has crashed.
$node_subscriber->stop('immediate') if $node_subscriber->is_alive;
$node_publisher->stop;

done_testing();

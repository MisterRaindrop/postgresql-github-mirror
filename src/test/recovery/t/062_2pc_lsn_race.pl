# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Reproduce a race between CheckPointTwoPhase() changing ondisk/LSNs and
# EndPrepare() reading those fields without syncing.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $node2 = PostgreSQL::Test::Cluster->new('twophase_endprepare_lsn_race');
$node2->init(allows_streaming => 1);
$node2->append_conf('postgresql.conf', q{
	max_prepared_transactions = 10
	log_checkpoints = on
	synchronous_standby_names = 'nonexistent_standby'
});
$node2->start;

if (!$node2->check_extension('injection_points'))
{
	plan skip_all => 'Extension injection_points not installed';
}

# The standby above never connects, so only the session that exercises
# EndPrepare() may wait for it.  Setup commits must not.
$node2->safe_psql('postgres', q{
	SET synchronous_commit = local;
	CREATE EXTENSION injection_points;
});
$node2->safe_psql(
	'postgres',
	q{SELECT injection_points_attach('twophase-prepare-before-syncrep',
									 'wait')});

# Pause PREPARE TRANSACTION in EndPrepare() right before it waits for the
# standby, when the gxact is already visible to the checkpointer.
my $prepare = $node2->background_psql('postgres');
my $pid = $prepare->query_safe('SELECT pg_backend_pid()');
chomp($pid);
$prepare->query_until(
	qr/prepare_started/, q{
	\echo prepare_started
	BEGIN;
	CREATE TABLE twophase_endprepare_race_table (id integer);
	PREPARE TRANSACTION 'twophase_endprepare_race_gid';
	\echo prepare_finished
});
$node2->wait_for_event('client backend', 'twophase-prepare-before-syncrep');

# The checkpoint writes the state file and clears prepare_end_lsn.
$node2->safe_psql('postgres', 'CHECKPOINT');

$node2->safe_psql('postgres',
	q{SELECT injection_points_wakeup('twophase-prepare-before-syncrep')});

# With a valid LSN PREPARE TRANSACTION waits for the standby forever.  With an
# already cleared LSN it returns at once and the backend goes idle.  Wait for
# either, then check which one it was.
$node2->poll_query_until('postgres', qq{
	SELECT wait_event = 'SyncRep' OR state = 'idle'
	FROM pg_stat_activity WHERE pid = $pid})
  or die "backend neither waits for the standby nor finished";
is($node2->safe_psql('postgres',
	qq{SELECT wait_event FROM pg_stat_activity WHERE pid = $pid}),
	'SyncRep',
	"PREPARE TRANSACTION waits for the synchronous standby");

# Release the backend from the sync rep wait.
$node2->safe_psql('postgres', qq{SELECT pg_cancel_backend($pid)});
$prepare->quit;
$node2->stop;

done_testing();

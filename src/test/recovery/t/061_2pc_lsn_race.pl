# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Reproduce a race between CheckPointTwoPhase() changing ondisk/LSNs and
# FinishPreparedTransaction() reading those fields without syncing.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $node1 = PostgreSQL::Test::Cluster->new('twophase_lsn_race');
$node1->init;
$node1->append_conf('postgresql.conf', q{
	max_prepared_transactions = 10
	log_checkpoints = on
});
$node1->start;

if (!$node1->check_extension('injection_points'))
{
	plan skip_all => 'Extension injection_points not installed';
}

$node1->safe_psql('postgres', q{CREATE EXTENSION injection_points});
$node1->safe_psql(
	'postgres',
	q{SELECT injection_points_attach('twophase-finish-after-ondisk-read',
									 'wait')});
$node1->safe_psql(
	'postgres',
	q{SELECT injection_points_attach('twophase-checkpoint-after-ondisk-set',
									 'wait')});

$node1->safe_psql('postgres', q{
	BEGIN;
	CREATE TABLE twophase_lsn_race_table (id integer);
	INSERT INTO twophase_lsn_race_table VALUES (1);
	PREPARE TRANSACTION 'twophase_lsn_race_gid';
});

# Pause COMMIT PREPARED after it has copied ondisk=false to its local variable.
my $commit = $node1->background_psql('postgres');
$commit->query_until(
	qr/commit_started/, q{
	\echo commit_started
	COMMIT PREPARED 'twophase_lsn_race_gid';
	\echo commit_finished
});
$node1->wait_for_event('client backend', 'twophase-finish-after-ondisk-read');

# The checkpoint now sets ondisk=true and stops before clearing the LSNs.
my $checkpoint = $node1->background_psql('postgres');
$checkpoint->query_until(
	qr/checkpoint_started/, q{
	\echo checkpoint_started
	CHECKPOINT;
	\echo checkpoint_finished
});
$node1->wait_for_event('checkpointer', 'twophase-checkpoint-after-ondisk-set');

# Finish the checkpoint first, so prepare_start_lsn is invalidated. Then
# resume COMMIT PREPARED, which still has the earlier ondisk=false value.
$node1->safe_psql('postgres',
	q{SELECT injection_points_wakeup('twophase-checkpoint-after-ondisk-set')});
$checkpoint->query_until(qr/checkpoint_finished/, '');

$node1->safe_psql('postgres',
	q{SELECT injection_points_wakeup('twophase-finish-after-ondisk-read')});

$checkpoint->quit;
$commit->quit;

ok($node1->is_alive(), "server is still running");

$node1->stop;

my $logfile = slurp_file($node1->logfile());
ok($logfile !~
	qr/TRAP: failed Assert*/,
	"no failed assertion");

# Reproduce a race between CheckPointTwoPhase() changing ondisk/LSNs and
# LookupGXact() reading those fields without syncing.
# TODO: add here...

done_testing();

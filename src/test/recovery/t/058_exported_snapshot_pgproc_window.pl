# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Test that a snapshot exported by CREATE_REPLICATION_SLOT ... (SNAPSHOT
# 'export') can treat a transaction as committed while that transaction is
# still in the procarray, so that concurrent MVCC snapshots taken by other
# backends still see it as in progress.
#
# A transaction's commit becomes visible to logical decoding as soon as its
# commit record has been inserted into WAL: SnapBuildCommitTxn() then puts
# the xid into the builder's list of committed transactions, and
# SnapBuildInitialSnapshot() converts that list into the exported MVCC
# snapshot's in-progress array, so the xid ends up treated as committed.
# The committing backend, however, removes itself from the procarray only
# later, in ProcArrayEndTransaction().  In between, the exported snapshot
# and any snapshot taken by GetSnapshotData() disagree about the
# transaction's outcome.
#
# The state transitions of the snapshot builder wait for the transactions
# listed in a xl_running_xacts record via XactLockTableWait() (see
# SnapBuildWaitSnapshot()), with one exception: the FULL_SNAPSHOT ->
# CONSISTENT transition does not wait.  That makes the window reachable
# deterministically: if the committing transaction is still in the
# procarray when that last transition happens, CREATE_REPLICATION_SLOT
# returns with the transaction already in the committed list of the
# exported snapshot.
#
# An injection point in CommitTransaction() makes the window deterministic:
# the committing session is stopped after RecordTransactionCommit() has
# flushed the commit record and updated the CLOG, but before
# ProcArrayEndTransaction().  Note that the CLOG is already up to date at
# that point, so the only observer that can notice the not-yet-finished
# transaction is the procarray - exactly the "exported snapshot sees the
# xact as committed, concurrent MVCC snapshots see it as in progress"
# inconsistency discussed in
#
# https://www.postgresql.org/message-id/aoiRAEAAzDnXfkDN@alvherre.pgsql
#
# A fix that makes SnapBuildInitialSnapshot() wait for such transactions to
# leave the procarray would change this test's expectations: the slot
# creation would then wait on the transaction's lock until the session is
# woken up, and the exported snapshot would agree with concurrent MVCC
# snapshots.
#
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;

use Test::More;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init(allows_streaming => 'logical');
$node->append_conf(
	'postgresql.conf', qq{
autovacuum = off
checkpoint_timeout = 1h
});
$node->start;

# Check if the extension injection_points is available, as it may be
# possible that this script is run with installcheck, where the module
# would not be installed by default.
if (!$node->check_extension('injection_points'))
{
	plan skip_all => 'Extension injection_points not installed';
}

$node->safe_psql('postgres', q(CREATE EXTENSION injection_points));
$node->safe_psql('postgres', q(CREATE TABLE t(i int)));

# Drive the snapshot builder of a CREATE_REPLICATION_SLOT (SNAPSHOT export)
# through its states, and stop a committing transaction (the "victim")
# after its commit record has been flushed but before its PGPROC entry is
# removed, so that the victim's commit is the last thing decoded before the
# builder reaches a consistent state.
#
# If $wake_victim is false, the victim is left stopped, and the slot
# creation returns while the victim is still in the procarray.  If it is
# true, the victim is woken up again before the builder can reach the
# consistent state, which closes the window.
#
# Returns the name of the exported snapshot, the victim's xid, and the
# walsender and victim sessions (kept alive by the caller as needed).
sub export_snapshot_across_victim_commit
{
	my ($slot_name, $value, $wake_victim) = @_;

	# First sacrificial transaction; being listed in the first
	# xl_running_xacts record the slot creation decodes drives the snapshot
	# builder from SNAPBUILD_START to SNAPBUILD_BUILDING_SNAPSHOT.
	my $s1 = $node->background_psql('postgres', on_error_stop => 1);
	$s1->query_safe('BEGIN');
	$s1->query_safe('SELECT txid_current()');

	# Walsender that creates the slot and exports the initial snapshot.
	# The command does not return until the snapshot builder has reached a
	# consistent point, which the rest of this test drives step by step.
	my $ws = $node->background_psql('postgres',
									on_error_stop => 1,
									replication => 'database');
	$ws->query_until(
		qr/slot_creation_started/,
		qq{\\echo slot_creation_started
		   CREATE_REPLICATION_SLOT $slot_name LOGICAL test_decoding (SNAPSHOT export)
		   ;
		   \\echo slot_done
	});

	# Wait until the slot's restart point has been fixed, so that the
	# standby snapshot logged below is guaranteed to be decoded by the slot
	# creation.
	$node->poll_query_until(
		'postgres',
		qq{SELECT count(*) FROM pg_replication_slots
		   WHERE slot_name = '$slot_name' AND restart_lsn IS NOT NULL},
		'1')
	  or die 'timed out when waiting for the slot to be created';

	# Log a xl_running_xacts record listing the first transaction.
	# Decoding it moves the builder to BUILDING_SNAPSHOT, where it waits
	# for that transaction's lock.
	$node->safe_psql('postgres', q{SELECT pg_log_standby_snapshot()});

	# Second sacrificial transaction, started only now so that its xid is
	# newer than the previous record's nextXid.  Being listed in the next
	# xl_running_xacts record moves the builder to FULL_SNAPSHOT.
	my $s2 = $node->background_psql('postgres', on_error_stop => 1);
	$s2->query_safe('BEGIN');
	my $x2 = $s2->query_safe('SELECT txid_current()');

	# End the first transaction.  The builder stops waiting for it, logs
	# another xl_running_xacts record (listing the second transaction),
	# decodes that record, moves to FULL_SNAPSHOT and waits for the second
	# transaction's lock.
	$s1->query_safe('ROLLBACK');

	# Wait until the builder waits for the second transaction's lock
	# specifically.  At that point the xl_running_xacts record that took
	# the builder to FULL_SNAPSHOT has been logged, so any xid assigned
	# from now on is newer than the builder's next_phase_at.
	$node->poll_query_until(
		'postgres',
		qq{SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
		   WHERE l.locktype = 'transactionid' AND l.transactionid = '$x2'
		     AND NOT l.granted AND a.backend_type = 'walsender'},
		'1')
	  or die 'timed out when waiting for the slot creation to wait for the second xact';

	# The victim transaction.  Stop it after its commit record has been
	# flushed and the CLOG has been updated, but before its PGPROC entry is
	# removed.
	my $t = $node->background_psql('postgres', on_error_stop => 1);
	$t->query_until(
		qr/about_to_commit/,
		qq{SELECT injection_points_attach('xact-commit-after-record', 'wait')
		   ;
		   BEGIN
		   ;
		   INSERT INTO t VALUES ($value)
		   ;
		   \\echo about_to_commit
		   COMMIT
		   ;
	});

	# Wait until the commit record is flushed, the CLOG is updated, and the
	# session is stopped before cleaning its PGPROC entry.
	$node->wait_for_event('client backend', 'xact-commit-after-record');

	# The victim is still in the procarray.
	my $xt = $node->safe_psql(
		'postgres',
		q{SELECT backend_xid FROM pg_stat_activity
		  WHERE wait_event = 'xact-commit-after-record'});
	ok($xt, "$slot_name: committing backend has not cleaned its PGPROC entry");

	# Detach the injection point so that nothing else can get stuck
	# anymore.
	$node->safe_psql('postgres',
					 q{SELECT injection_points_detach('xact-commit-after-record')});

	if ($wake_victim)
	{
		# Close the window: let the victim's commit run to completion, so
		# that it has left the procarray by the time the builder reaches
		# the consistent state.
		$node->safe_psql('postgres',
						 q{SELECT injection_points_wakeup('xact-commit-after-record')});

		# Wait for the victim's COMMIT to actually return.
		$t->query_safe('SELECT 1');
	}

	# End the second transaction.  The builder wakes and logs a
	# xl_running_xacts record.  If the victim is still stopped, that record
	# lists it as running (its PGPROC entry is still there), and decoding
	# the record takes the builder from FULL_SNAPSHOT to CONSISTENT, a
	# transition that does not wait for the transactions the record lists.
	# The victim's commit record precedes that record in WAL, so the victim
	# is in the committed list of the snapshot that gets exported.  If the
	# victim was woken up, the record lists no transactions and takes the
	# builder to CONSISTENT only after the victim fully finished.
	$s2->query_safe('ROLLBACK');

	# The slot creation now returns.
	my $slot_out = $ws->query_until(qr/slot_done/, '');
	like($slot_out, qr/^\Q$slot_name\E\|/m, "$slot_name: slot creation returned");

	my ($snapname) = $slot_out =~ /\|([0-9A-Fa-f]+-[0-9A-Fa-f]+-\d+)\|/m;
	ok(defined $snapname, "$slot_name: snapshot was exported");
	note("$slot_name: exported snapshot name: "
		 . (defined $snapname ? $snapname : '<none>'));

	$s1->quit;
	$s2->quit;

	return ($snapname, $xt, $ws, $t);
}

# Scenario 1: the slot creation exports its snapshot while the victim is
# stopped after its commit record was flushed, before cleaning its PGPROC
# entry.
my ($snapname, $xt, $ws1, $t1) =
  export_snapshot_across_victim_commit('slot1', 1, 0);

# The SQL-visible transaction status still reflects the unfinished commit:
# pg_xact_status() deliberately checks the procarray before the CLOG (see
# its comment in xid8funcs.c), like MVCC visibility checks do.
is( $node->safe_psql('postgres', qq{SELECT pg_xact_status('$xt')}),
	'in progress',
	'pg_xact_status() still sees the transaction as in progress');

# A concurrent backend still sees the victim as in progress: its row is
# invisible to a fresh MVCC snapshot.
is( $node->safe_psql('postgres', q{SELECT count(*) FROM t}),
	'0',
	'concurrent MVCC snapshot sees the committing xact as in progress');

# The exported snapshot, however, treats the victim as committed: the row
# is visible through it.  Note that this also proves that the victim's
# commit was already recorded in the CLOG when the snapshot was exported:
# otherwise HeapTupleSatisfiesMVCC() would have concluded from
# TransactionIdDidCommit() that the transaction "must have aborted or
# crashed" and the row would be invisible here, too.  The two results above
# are inconsistent with each other, which is the point of this test.
is( $node->safe_psql(
		'postgres',
		qq{BEGIN ISOLATION LEVEL REPEATABLE READ;
		   SET TRANSACTION SNAPSHOT '$snapname';
		   SELECT count(*) FROM t}),
	'1',
	'exported snapshot treats the still-in-procarray xact as committed');

# Let the victim finish its commit, and keep the slot.
$node->safe_psql('postgres',
				 q{SELECT injection_points_wakeup('xact-commit-after-record')});
$t1->query_safe('SELECT 1');
$t1->quit;
$ws1->quit;

# Sanity check: once the commit has fully finished, all snapshots agree
# again.
is( $node->safe_psql('postgres', q{SELECT count(*) FROM t}),
	'1', 'row is visible everywhere once the commit finished');

# Scenario 2 (control): same choreography, but the victim is woken up
# before the builder reaches the consistent state, so the exported snapshot
# is taken after the victim's commit has fully finished.
($snapname, $xt, my $ws2, my $t2) =
  export_snapshot_across_victim_commit('slot2', 2, 1);

# Both kinds of snapshots now agree: the row is visible through each.
is( $node->safe_psql('postgres', q{SELECT count(*) FROM t}),
	'2',
	'control: concurrent MVCC snapshot sees the finished xact as committed');
is( $node->safe_psql(
		'postgres',
		qq{BEGIN ISOLATION LEVEL REPEATABLE READ;
		   SET TRANSACTION SNAPSHOT '$snapname';
		   SELECT count(*) FROM t}),
	'2',
	'control: exported snapshot agrees with concurrent MVCC snapshots');

$t2->quit;
$ws2->quit;

done_testing();

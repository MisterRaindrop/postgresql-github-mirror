# Copyright (c) 2026, PostgreSQL Global Development Group

# Test how the autoprewarm worker reacts to other lock requests on a relation
# it is prewarming. It gives the relation up for a request that conflicts with
# its AccessShareLock, and carries on for one that does not.

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

# The worker loads the dump only at startup and injection points do not survive
# a restart, so the wait can only be armed after a restart. The table must be
# big enough that the worker is still reading it by then, and the buffer pool
# big enough to hold it, since the worker stops prewarming once buffers run
# short. Keep both well under 2GB so that NBuffers * BLCKSZ stays
# representable on 32-bit platforms.
$node->append_conf(
	'postgresql.conf', qq{
shared_preload_libraries = 'pg_prewarm,injection_points'
pg_prewarm.autoprewarm = true
pg_prewarm.autoprewarm_interval = 0
autovacuum = off
shared_buffers = '512MB'
});
$node->start;

# The injection_points extension may not be installed under installcheck.
if (!$node->check_extension('injection_points'))
{
	plan skip_all => 'Extension injection_points not installed';
}

$node->safe_psql('postgres', q(
	CREATE EXTENSION pg_prewarm;
	CREATE EXTENSION injection_points;
));

$node->safe_psql('postgres', q(
	CREATE TABLE warm_tbl (id int, pad text);
	INSERT INTO warm_tbl SELECT g, repeat('x', 500)
		FROM generate_series(1, 500000) g;
));

# The table must exceed the worker's lock-check interval (in blocks) so that
# the worker reaches the injection point while still scanning it.
my $nblocks = $node->safe_psql('postgres',
	"SELECT pg_relation_size('warm_tbl') / current_setting('block_size')::int");
ok($nblocks > 32, "table has more than 32 blocks ($nblocks)");

# Warm the table and record its blocks so the worker reloads them on restart.
$node->safe_psql('postgres', "SELECT pg_prewarm('warm_tbl', 'buffer')");
$node->safe_psql('postgres', "SELECT autoprewarm_dump_now()");

$node->restart;

# Pause the worker while it holds AccessShareLock on warm_tbl. The condition
# matters: other relations in the dump reach this point first (some catalogs
# have more than 32 blocks), and the worker would then be holding a lock on the
# wrong relation, so the TRUNCATE below would not block.
$node->safe_psql('postgres',
	"SELECT injection_points_attach('autoprewarm-before-lock-check', 'wait', 'warm_tbl')");
$node->wait_for_event('autoprewarm worker', 'autoprewarm-before-lock-check');

# TRUNCATE now blocks on the AccessExclusiveLock the worker conflicts with.
my $truncate = $node->background_psql('postgres');
$truncate->query_until(qr/starting_truncate/, q(
	\echo starting_truncate
	TRUNCATE warm_tbl;
));
$node->poll_query_until('postgres', q(
	SELECT count(*) > 0 FROM pg_stat_activity
	WHERE query LIKE '%TRUNCATE warm_tbl%' AND wait_event_type = 'Lock';
)) or die "timed out waiting for TRUNCATE to block on the lock";

# Resume the worker; it should see the waiter and release its lock.
my $log_offset = -s $node->logfile;
$node->safe_psql('postgres',
	"SELECT injection_points_detach('autoprewarm-before-lock-check')");
$node->safe_psql('postgres',
	"SELECT injection_points_wakeup('autoprewarm-before-lock-check')");

$truncate->quit;
pass('TRUNCATE completed while autoprewarm worker was prewarming');

# Having given up the table, the worker warmed fewer blocks than it dumped.
$node->wait_for_log(
	qr/autoprewarm successfully prewarmed \d+ of \d+ previously-loaded blocks/,
	$log_offset);
my $summary = slurp_file($node->logfile, $log_offset);
my ($prewarmed, $total) = $summary =~
	/successfully prewarmed (\d+) of (\d+) previously-loaded blocks/;
cmp_ok($prewarmed, '<', $total,
	"worker gave up early: prewarmed $prewarmed of $total blocks");

# Now a request that does not conflict, which must not make the worker give up.
# The worker takes AccessShareLock through the fast path, so it has no proclock.
# ShareUpdateExclusiveLock is too strong for the fast path, so it enters the
# relation in the main lock table, but too weak to conflict with the worker, so
# nothing moves the worker's lock there and it is granted at once, leaving no
# waiter. The worker must find the relation in the main lock table, find no
# proclock of its own, and prewarm the relation to the end. VACUUM, ANALYZE and
# CREATE INDEX CONCURRENTLY all take this mode.
#
# The TRUNCATE above emptied the table, so fill and dump it again.
$node->safe_psql('postgres', q(
	INSERT INTO warm_tbl SELECT g, repeat('x', 500)
		FROM generate_series(1, 500000) g;
));
$node->safe_psql('postgres', "SELECT pg_prewarm('warm_tbl', 'buffer')");
$node->safe_psql('postgres', "SELECT autoprewarm_dump_now()");

$node->restart;

# Pause the worker again, this time to inspect the locks it holds.
$node->safe_psql('postgres',
	"SELECT injection_points_attach('autoprewarm-before-lock-check', 'wait', 'warm_tbl')");
$node->wait_for_event('autoprewarm worker', 'autoprewarm-before-lock-check');

is( $node->safe_psql(
		'postgres', q(
	SELECT count(*) FROM pg_locks
	WHERE relation = 'warm_tbl'::regclass
		AND mode = 'AccessShareLock' AND fastpath;
)),
	'1',
	'worker holds AccessShareLock on the relation through the fast path');

# Another session takes ShareUpdateExclusiveLock and holds it.
my $holder = $node->background_psql('postgres');
$holder->query_safe(
	'BEGIN; LOCK TABLE warm_tbl IN SHARE UPDATE EXCLUSIVE MODE;');
is( $node->safe_psql(
		'postgres', q(
	SELECT count(*) FROM pg_locks
	WHERE relation = 'warm_tbl'::regclass
		AND mode = 'ShareUpdateExclusiveLock' AND granted AND NOT fastpath;
)),
	'1',
	'relation is in the main lock table for a mode that does not conflict');

# Resume the worker; it must prewarm the relation to the end.
$log_offset = -s $node->logfile;
$node->safe_psql('postgres',
	"SELECT injection_points_detach('autoprewarm-before-lock-check')");
$node->safe_psql('postgres',
	"SELECT injection_points_wakeup('autoprewarm-before-lock-check')");

$node->wait_for_log(
	qr/autoprewarm successfully prewarmed \d+ of \d+ previously-loaded blocks/,
	$log_offset);
$summary = slurp_file($node->logfile, $log_offset);
unlike($summary, qr/failed to re-find shared proclock object/,
	'worker did not fail looking for a proclock it never had');
($prewarmed, $total) = $summary =~
	/successfully prewarmed (\d+) of (\d+) previously-loaded blocks/;
is($prewarmed, $total,
	"worker kept the relation: prewarmed $prewarmed of $total blocks");

$holder->query_safe('ROLLBACK');
$holder->quit;

$node->stop;
done_testing();

# Copyright (c) 2026, PostgreSQL Global Development Group

use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node_publisher = PostgreSQL::Test::Cluster->new('publisher');
$node_publisher->init(allows_streaming => 'logical');
$node_publisher->start;

my $node_subscriber = PostgreSQL::Test::Cluster->new('subscriber');
$node_subscriber->init;
$node_subscriber->append_conf('postgresql.conf', q(
max_logical_replication_workers = 10
max_parallel_apply_workers_per_subscription = 4
));
$node_subscriber->start;
$node_subscriber->safe_psql('postgres',
	'CREATE EXTENSION injection_points');

$node_publisher->safe_psql('postgres', q(
CREATE TABLE test_tab (id integer, payload text);
ALTER TABLE test_tab REPLICA IDENTITY FULL;
INSERT INTO test_tab VALUES (0, 'idle');
CREATE PUBLICATION regress_pub FOR ALL TABLES;
));

my $publisher_connstr = $node_publisher->connstr . ' dbname=postgres';
$node_subscriber->safe_psql('postgres', qq(
CREATE TABLE test_tab (id integer, payload text);
ALTER TABLE test_tab REPLICA IDENTITY FULL;
CREATE SUBSCRIPTION regress_sub CONNECTION '$publisher_connstr'
	PUBLICATION regress_pub WITH (streaming = parallel);
));
$node_subscriber->wait_for_subscription_sync($node_publisher, 'regress_sub');

$node_subscriber->safe_psql('postgres',
	q(SELECT injection_points_attach('parallel-worker-before-commit', 'wait')));

# Transaction A: retains more than half the dependency budget, but stays below the limit.
$node_publisher->safe_psql('postgres', q(
INSERT INTO test_tab VALUES (1, repeat('p', 10 * 1024 * 1024));
));
$node_subscriber->wait_for_event('logical replication parallel worker',
	'parallel-worker-before-commit');

# crosses the limit. Hold it before applying its target UPDATE.
$node_subscriber->safe_psql('postgres', q(
SELECT injection_points_attach('apply-update-before-open-indices', 'wait');
));

my $log_offset = -s $node_subscriber->logfile;
# Transaction B.
$node_publisher->safe_psql('postgres', q(
BEGIN;
INSERT INTO test_tab VALUES (2, repeat('t', 7 * 1024 * 1024));
UPDATE test_tab SET payload = 'first' WHERE id = 0;
COMMIT;
));
$node_subscriber->wait_for_log(qr/parallel apply suspended:/, $log_offset);

# Let A commit. Its entries drain the estimate below half and release B's
# commit-order barrier. B then stops before applying its untracked UPDATE.
$node_subscriber->safe_psql('postgres', q(
SELECT injection_points_detach('parallel-worker-before-commit');
SELECT injection_points_wakeup('parallel-worker-before-commit');
));
$node_subscriber->wait_for_log(qr/parallel apply resumed:/, $log_offset);
$node_subscriber->wait_for_event('logical replication parallel worker',
	'apply-update-before-open-indices');

$node_subscriber->safe_psql('postgres', q(
SELECT injection_points_detach('apply-update-before-open-indices');
));

# If we update the same entry as B's and if parallel apply resumed too early,
# The C's update runs before B's update and is skipped as update_missing.
my $update_offset = -s $node_subscriber->logfile;

# Transaction C:
$node_publisher->safe_psql('postgres',
	q(UPDATE test_tab SET payload = 'second' WHERE id = 0));

$node_subscriber->wait_for_log(qr/conflict.*update_missing|update_missing/s,
	$update_offset);

$node_subscriber->safe_psql('postgres', q(
SELECT injection_points_wakeup('apply-update-before-open-indices');
));
$node_publisher->wait_for_catchup('regress_sub');

# We should get C's update here:
is($node_subscriber->safe_psql('postgres',
	q(SELECT payload FROM test_tab WHERE id = 0)),
	'second', 'later update is applied after the suspended transaction');

done_testing();
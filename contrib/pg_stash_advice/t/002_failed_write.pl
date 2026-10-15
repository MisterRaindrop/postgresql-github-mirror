# Copyright (c) 2016-2026, PostgreSQL Global Development Group

# Check that changes are not lost when the worker fails to write the dump file
# and is then restarted.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');

$node->init;
$node->append_conf(
	'postgresql.conf',
	qq{shared_preload_libraries = 'pg_plan_advice, pg_stash_advice'
pg_stash_advice.persist = true
pg_stash_advice.persist_interval = 1});
$node->start;

$node->safe_psql("postgres", "CREATE EXTENSION pg_stash_advice;\n");

my $log_offset = -s $node->logfile;
$node->safe_psql(
	"postgres", qq{
	SELECT pg_create_advice_stash('stash_a');
	SELECT pg_set_stashed_advice('stash_a', 1001, 'SEQ_SCAN(t)');
});
$node->wait_for_log(qr/saved 1 advice stashes and 1 entries/, $log_offset);

# Make the next write fail by putting a directory where the worker wants to
# create its temporary file.
my $tmpfile = $node->data_dir . '/pg_stash_advice.tsv.tmp';
mkdir($tmpfile) or die "could not create directory \"$tmpfile\": $!";

$log_offset = -s $node->logfile;
$node->safe_psql("postgres",
	"SELECT pg_set_stashed_advice('stash_a', 1002, 'SEQ_SCAN(u)');");
$node->wait_for_log(
	qr/could not open file "pg_stash_advice.tsv.tmp"/, $log_offset);
$node->poll_query_until("postgres",
	"SELECT count(*) = 0 FROM pg_stat_activity WHERE backend_type = 'pg_stash_advice worker'"
) or die "timed out waiting for worker to exit";

# Remove the obstacle and start a new worker without waiting for the
# postmaster to restart the old one. It should notice that the previous
# worker's changes were never saved.
rmdir($tmpfile) or die "could not remove directory \"$tmpfile\": $!";
$log_offset = -s $node->logfile;
$node->safe_psql("postgres", "SELECT pg_start_stash_advice_worker();");
$node->wait_for_log(qr/saved 1 advice stashes and 2 entries/, $log_offset);

# An immediate shutdown skips the final write, so whatever is reloaded must
# have been saved by the new worker.
$node->stop('immediate');
$log_offset = -s $node->logfile;
$node->start;
$node->wait_for_log(qr/loaded 1 advice stashes and 2 entries/, $log_offset);

my $result = $node->safe_psql("postgres",
	"SELECT query_id, advice_string FROM pg_get_advice_stash_contents('stash_a') ORDER BY query_id"
);
is($result, "1001|SEQ_SCAN(t)\n1002|SEQ_SCAN(u)",
	'change survived failed write and immediate shutdown');

$node->stop;

done_testing();

# Copyright (c) 2026, PostgreSQL Global Development Group

# Test switching the WAL source from archive to streaming replication.
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1, has_archiving => 1);
$primary->append_conf(
	'postgresql.conf', qq(
checkpoint_timeout = 1h
autovacuum = off
));
$primary->start;
$primary->safe_psql('postgres',
	"SELECT pg_create_physical_replication_slot('standby_slot')");
$primary->safe_psql('postgres',
	"CREATE TABLE tab_int AS SELECT generate_series(1, 10) AS a");

my $backup_name = 'my_backup';
$primary->backup($backup_name);

my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup(
	$primary, $backup_name,
	has_streaming => 1,
	has_restoring => 1);

my $retry_interval = 1;
$standby->append_conf(
	'postgresql.conf', qq(
primary_slot_name = 'standby_slot'
streaming_replication_retry_interval = '${retry_interval}s'
log_min_messages = 'debug2'
));
$standby->start;
$primary->wait_for_catchup($standby);

$standby->stop;
for my $i (1 .. 10)
{
	$primary->safe_psql('postgres',
		"INSERT INTO tab_int VALUES (generate_series(11, 20));");
	$primary->safe_psql('postgres', "SELECT pg_switch_wal();");
}

my $current_lsn =
  $primary->safe_psql('postgres', "SELECT pg_current_wal_lsn()");
$primary->advance_wal(1);

my $walfile_name =
  $primary->safe_psql('postgres', "SELECT pg_walfile_name('$current_lsn')");
$primary->poll_query_until('postgres',
	"SELECT count(*) = 1 FROM pg_stat_archiver WHERE last_archived_wal = '$walfile_name';"
) or die "Timed out while waiting for archiving by primary";

my $log_offset = -s $standby->logfile;
my $delay = $retry_interval * 5;
$standby->append_conf(
	'postgresql.conf', qq(
recovery_min_apply_delay = '${delay}s'
));
$standby->start;
$primary->wait_for_catchup($standby);

$standby->wait_for_log(
	qr/DEBUG: ( [A-Z0-9]+:)? switched WAL source from archive to stream after timeout/,
	$log_offset);
$standby->wait_for_log(
	qr/LOG: ( [A-Z0-9]+:)? started streaming WAL from primary at .* on timeline .*/,
	$log_offset);

my $primary_count =
  $primary->safe_psql('postgres', "SELECT count(*) FROM tab_int;");
my $standby_count =
  $standby->safe_psql('postgres', "SELECT count(*) FROM tab_int;");
is($primary_count, $standby_count,
	'data from primary is streamed to standby');

done_testing();
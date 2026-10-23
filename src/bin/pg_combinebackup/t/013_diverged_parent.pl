# Copyright (c) 2026, PostgreSQL Global Development Group
#
# Test that an incremental backup is refused when the prior backup requires
# WAL from past the point where this server's history left that timeline.
# That happens after a failover: the last backup taken on the old primary can
# include transactions that never reached the standby that was promoted.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Set up a new database instance.
my $node1 = PostgreSQL::Test::Cluster->new('node1');
$node1->init(has_archiving => 1, allows_streaming => 1);
$node1->append_conf('postgresql.conf', 'summarize_wal = on');
$node1->start;

$node1->safe_psql('postgres', <<EOM);
CREATE TABLE mytable (a int, b text);
INSERT INTO mytable VALUES (1, 'avocado');
EOM

# Take a full backup to create the standby from.
$node1->backup('standby_base');

# Take the full backup that will later be used as the prior backup.
my $parentpath = $node1->backup_dir . '/parent';
$node1->command_ok(
	[
		'pg_basebackup',
		'--pgdata' => $parentpath,
		'--no-sync',
		'--checkpoint' => 'fast',
	],
	"full backup from node1");

my $manifest = slurp_file("$parentpath/backup_manifest");
$manifest =~ /"Start-LSN": "([0-9A-F\/]+)", "End-LSN": "([0-9A-F\/]+)"/
  or die "could not find WAL range in backup manifest";
my ($parent_start, $parent_end) = ($1, $2);

# Create a standby that stops replaying just after the start of that backup,
# then promote it. Its timeline switch falls between the start and the end of
# the WAL range that the backup requires.
my $node2 = PostgreSQL::Test::Cluster->new('node2');
$node2->init_from_backup($node1, 'standby_base', has_streaming => 1);
$node2->append_conf('postgresql.conf', <<EOM);
recovery_target_lsn = '$parent_start'
recovery_target_action = 'pause'
EOM
$node2->start();
$node2->poll_query_until('postgres',
	"SELECT pg_get_wal_replay_pause_state() = 'paused';");
$node2->safe_psql('postgres', "SELECT pg_promote()");
$node2->poll_query_until('postgres', "SELECT pg_is_in_recovery() = 'f';");

# Generate WAL on the new timeline until we are past the end of the prior
# backup, so that the existing "this backup starts at" check does not apply.
$node2->safe_psql('postgres', "INSERT INTO mytable VALUES (2, 'blackberry')");
while ($node2->safe_psql('postgres',
		"SELECT pg_current_wal_lsn() <= '$parent_end'::pg_lsn") eq 't')
{
	$node2->safe_psql('postgres', "SELECT pg_switch_wal()");
	$node2->safe_psql('postgres', "INSERT INTO mytable VALUES (3, 'cherry')");
}

# An incremental backup relative to a backup taken before the switch point
# still works.
$node2->command_ok(
	[
		'pg_basebackup',
		'--pgdata' => $node1->backup_dir . '/incr_ok',
		'--no-sync',
		'--checkpoint' => 'fast',
		'--incremental' => $node1->backup_dir . '/standby_base/backup_manifest',
	],
	"incremental backup relative to a backup from before the switch");

# An incremental backup relative to the backup that extends past the switch
# point must be refused.
$node2->command_fails_like(
	[
		'pg_basebackup',
		'--pgdata' => $node1->backup_dir . '/incr_bad',
		'--no-sync',
		'--checkpoint' => 'fast',
		'--incremental' => $parentpath . '/backup_manifest',
	],
	qr/manifest requires WAL from final timeline 1 ending at .*, but this server switched timelines at/,
	"incremental backup relative to a backup that extends past the switch");

done_testing();

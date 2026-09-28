# Copyright (c) 2026, PostgreSQL Global Development Group

# Verify that the backup size estimate reported for an incremental backup
# reflects the amount of data that will actually be sent, rather than the size
# of a full backup.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init(allows_streaming => 1);
$node->append_conf('postgresql.conf', 'summarize_wal = on');
$node->append_conf('postgresql.conf', 'autovacuum = off');
$node->start;

# Enough data that a full backup and an incremental one differ clearly in
# size, without writing more than necessary.
$node->safe_psql('postgres', <<EOM);
CREATE TABLE big AS
  SELECT g AS i, repeat('x', 500) AS pad FROM generate_series(1, 20000) g;
CHECKPOINT;
EOM

# Runs a backup with --progress and returns the total reported by the last
# progress line, in kB.
sub reported_total
{
	my ($path, @extra) = @_;
	my ($stdout, $stderr) = ('', '');

	my $result = IPC::Run::run(
		[
			'pg_basebackup',
			'--host' => $node->host,
			'--port' => $node->port,
			'--pgdata' => $path,
			'--no-sync',
			'--progress',
			'--checkpoint' => 'fast',
			@extra
		],
		'>' => \$stdout,
		'2>' => \$stderr);
	ok($result, "backup into $path succeeded")
	  or die "pg_basebackup failed: $stderr";

	# Progress lines are separated by carriage returns and look like
	# "  6519/346720 kB (1%), 1/1 tablespace".
	my @lines = grep { /kB/ } split(/[\r\n]+/, $stderr);
	ok(@lines > 0, "progress was reported for $path")
	  or die "no progress output for $path";

	my ($total) = $lines[-1] =~ m{\d+/(\d+) kB};
	defined($total)
	  or die "could not parse progress line for $path: $lines[-1]";
	return $total;
}

my $backup_dir = $node->backup_dir;
my $full_total = reported_total("$backup_dir/full");

# A small change, so that the incremental backup has very little to send.
$node->safe_psql('postgres', <<EOM);
INSERT INTO big
  SELECT g, repeat('y', 500) FROM generate_series(20001, 22000) g;
CHECKPOINT;
EOM

my $incr_total = reported_total("$backup_dir/incr",
	'--incremental' => "$backup_dir/full/backup_manifest");

note "full backup reported a total of $full_total kB";
note "incremental backup reported a total of $incr_total kB";

# An incremental backup sends only a fraction of the cluster, so an estimate
# that still describes a full backup is far too large.
cmp_ok($incr_total, '<', $full_total / 2,
	'incremental backup estimate is much smaller than a full backup estimate'
);

done_testing();

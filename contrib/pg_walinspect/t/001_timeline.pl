# Copyright (c) 2026, PostgreSQL Global Development Group

# Test timeline selection when XLogFindNextRecord() reads a record spanning
# segments and then rewinds to its beginning.
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init(allows_streaming => 1, extra => ['--wal-segsize=1']);
# Keep old segments across the checkpoints that follow each promotion.
$node->append_conf('postgresql.conf', "wal_keep_size = '64MB'");
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_walinspect');

# Write a record larger than a segment, starting right after a segment
# switch.  It begins in segment N and ends about halfway through N+1.
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');
my $before = $node->lsn('insert');
my $record_end = $node->safe_psql('postgres',
	"SELECT pg_logical_emit_message(false, 'test', repeat('x', 1536 * 1024), true)"
);
my $record_start = $node->safe_psql(
	'postgres', qq[
	SELECT start_lsn FROM pg_get_wal_records_info('$before', '$record_end')
	WHERE resource_manager = 'LogicalMessage';
]);

# Restart in standby mode and promote, switching to a new timeline.
# Timeline 2 begins in segment N+1, so it has no copy of segment N.
$node->set_standby_mode;
$node->restart;
$node->promote;

# Timeline 3 begins in a later segment, so segment N+1 stays on timeline 2.
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');
$node->set_standby_mode;
$node->restart;
$node->promote;

# Reading the record leaves the reader on timeline 2's copy of segment N+1.
# Rewinding to the record's start must return to timeline 1's segment N.
my ($ret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT end_lsn FROM pg_get_wal_record_info('$record_start')");
is($stdout, $record_end,
	'reread a cross-segment record after its timeline became historical')
  or diag($stderr);

done_testing();

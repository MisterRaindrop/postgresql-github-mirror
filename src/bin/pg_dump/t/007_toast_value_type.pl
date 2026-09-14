# Copyright (c) 2026, PostgreSQL Global Development Group

# Tests how a dump and restore treats the type a TOAST relation uses for its
# chunk_id attribute. That type comes from the toast_value_type reloption of
# the relation owning it, read only when the TOAST relation is created, so the
# reloptions of a relation and the type its TOAST relation uses can differ.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# 2^32 + 100000.
my $big_next_oid = '4295067296';

# Type of the chunk_id attribute of the TOAST relation of a relation.
sub chunk_id_type
{
	my ($node, $dbname, $relname) = @_;

	return $node->safe_psql(
		$dbname,
		"SELECT a.atttypid::regtype FROM pg_class AS c, pg_attribute AS a
		   WHERE c.oid = '$relname'::regclass AND
				 a.attrelid = c.reltoastrelid AND a.attname = 'chunk_id'");
}

# Whether all the out-of-line values of a relation have a chunk_id that does
# not fit in an oid. The threshold compared against is the OID counter set
# below, which sits above the largest oid.
sub chunk_ids_past_oid_max
{
	my ($node, $dbname, $relname) = @_;

	return $node->safe_psql(
		$dbname,
		"SELECT bool_and(pg_column_toast_chunk_id(val) > '$big_next_oid'::oid8)
		   FROM $relname");
}

# Reloptions of a relation, as a string, or an empty string when it has none.
sub reloptions
{
	my ($node, $dbname, $relname) = @_;

	return $node->safe_psql(
		$dbname,
		"SELECT coalesce(array_to_string(reloptions, ','), '')
		   FROM pg_class WHERE oid = '$relname'::regclass");
}

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;

# Push the OID counter past 2^32 before the first start, so that the chunk
# identifiers handed out in an oid8 TOAST relation do not fit in an oid. A
# relation that loses oid8 along the way is then visible in the values
# themselves and not just in the catalogs.
command_ok([ 'pg_resetwal', '--next-oid' => $big_next_oid, $node->data_dir ],
	'set an OID counter past 2^32');

$node->start;

$node->safe_psql('postgres', 'CREATE DATABASE src');
$node->safe_psql('postgres', 'CREATE DATABASE dst');

# Test case 1: reloptions that say nothing about the type in use.
#
# A reset of toast_value_type removes the entry from the reloptions of a
# relation but leaves its TOAST relation alone, which keeps the chunk_id type
# it was created with.
#
# EXTERNAL storage keeps the values out of line without compressing them
# first.
$node->safe_psql(
	'src', qq{
CREATE TABLE t_oid8_reset (id int, val text)
  WITH (toast_value_type = 'oid8');
ALTER TABLE t_oid8_reset ALTER COLUMN val SET STORAGE EXTERNAL;
INSERT INTO t_oid8_reset
  SELECT g, repeat('a', 5000) FROM generate_series(1, 3) g;
});

is(chunk_id_type($node, 'src', 't_oid8_reset'),
	'oid8', 't_oid8_reset: chunk_id is an oid8 when asked for at creation');
is(chunk_ids_past_oid_max($node, 'src', 't_oid8_reset'),
	't', 't_oid8_reset: chunk identifiers do not fit in an oid');

$node->safe_psql('src', 'ALTER TABLE t_oid8_reset RESET (toast_value_type)');

is(reloptions($node, 'src', 't_oid8_reset'),
	'', 't_oid8_reset: reloptions are empty after the reset');
is(chunk_id_type($node, 'src', 't_oid8_reset'),
	'oid8', 't_oid8_reset: the reset does not change the TOAST relation');

# Test case 2: reloptions that specify a type.
#
# A table created with oid, whose out-of-line values get identifiers to match,
# and a set of the option that records a request for oid8.
$node->safe_psql(
	'src', qq{
CREATE TABLE t_oid_to_oid8 (id int, val text);
ALTER TABLE t_oid_to_oid8 ALTER COLUMN val SET STORAGE EXTERNAL;
INSERT INTO t_oid_to_oid8
  SELECT g, repeat('b', 5000) FROM generate_series(1, 3) g;
ALTER TABLE t_oid_to_oid8 SET (toast_value_type = 'oid8');
});

# The set does not recreate the TOAST relation. The OID counter sits past
# 2^32, yet an oid identifier still has to fit in one.
is(chunk_id_type($node, 'src', 't_oid_to_oid8'),
	'oid', 't_oid_to_oid8: the set does not change the TOAST relation');
is(chunk_ids_past_oid_max($node, 'src', 't_oid_to_oid8'),
	'f', 't_oid_to_oid8: chunk identifiers still fit in an oid');

# The same the other way round, a table created with oid8 asking back for oid.
$node->safe_psql(
	'src', qq{
CREATE TABLE t_oid8_to_oid (id int, val text)
  WITH (toast_value_type = 'oid8');
ALTER TABLE t_oid8_to_oid ALTER COLUMN val SET STORAGE EXTERNAL;
INSERT INTO t_oid8_to_oid
  SELECT g, repeat('c', 5000) FROM generate_series(1, 3) g;
ALTER TABLE t_oid8_to_oid SET (toast_value_type = 'oid');
});

is(chunk_id_type($node, 'src', 't_oid8_to_oid'),
	'oid8', 't_oid8_to_oid: the set does not change the TOAST relation');
is(chunk_ids_past_oid_max($node, 'src', 't_oid8_to_oid'),
	't', 't_oid8_to_oid: chunk identifiers do not fit in an oid');

# Dump and restore.
my $dumpfile = $node->basedir . '/toast_value_type.dump';
my $textfile = $node->basedir . '/toast_value_type.sql';

$node->command_ok(
	[ 'pg_dump', '--format' => 'custom', '--file' => $dumpfile, 'src' ],
	'dump the source database');
$node->command_ok([ 'pg_restore', '--file' => $textfile, $dumpfile ],
	'convert the dump to text');

my $dump = slurp_file($textfile);

like(
	$dump,
	qr/CREATE TABLE public\.t_oid8_reset \(\n[^)]*\)\nWITH \(toast_value_type=oid8\);/,
	't_oid8_reset: the dump asks for oid8');
like(
	$dump,
	qr/CREATE TABLE public\.t_oid_to_oid8 \(\n[^)]*\)\nWITH \(toast_value_type=oid8\);/,
	't_oid_to_oid8: the dump asks for oid8');
like(
	$dump,
	qr/CREATE TABLE public\.t_oid8_to_oid \(\n[^)]*\)\nWITH \(toast_value_type=oid\);/,
	't_oid8_to_oid: the dump asks for oid');

$node->command_ok(
	[ 'pg_restore', '--dbname' => 'dst', $dumpfile ],
	'restore into the destination database');

is(chunk_id_type($node, 'dst', 't_oid8_reset'),
	'oid8', 't_oid8_reset: the restored TOAST relation still uses oid8');
is(chunk_ids_past_oid_max($node, 'dst', 't_oid8_reset'),
	't', 't_oid8_reset: the restored chunk identifiers do not fit in an oid');
is( $node->safe_psql(
		'dst', 'SELECT count(*), min(length(val)) FROM t_oid8_reset'),
	'3|5000',
	't_oid8_reset: the out-of-line values are restored intact');

# The restore is what applies the request, and the values come over intact.
is(chunk_id_type($node, 'dst', 't_oid_to_oid8'),
	'oid8', 't_oid_to_oid8: the restored TOAST relation uses oid8');
is(chunk_ids_past_oid_max($node, 'dst', 't_oid_to_oid8'),
	't',
	't_oid_to_oid8: the restored chunk identifiers do not fit in an oid');
is( $node->safe_psql(
		'dst', 'SELECT count(*), min(length(val)) FROM t_oid_to_oid8'),
	'3|5000',
	't_oid_to_oid8: the out-of-line values are restored intact');

# The same value stored again gets an identifier no oid could hold.
$node->safe_psql('dst',
	"INSERT INTO t_oid_to_oid8 SELECT 4, repeat('b', 5000)");

is(chunk_ids_past_oid_max($node, 'dst', 't_oid_to_oid8'),
	't', 't_oid_to_oid8: a new identifier does not fit in an oid');

# The other way round, the restored relation uses oid and so does a new value.
is(chunk_id_type($node, 'dst', 't_oid8_to_oid'),
	'oid', 't_oid8_to_oid: the restored TOAST relation uses oid');
is(chunk_ids_past_oid_max($node, 'dst', 't_oid8_to_oid'),
	'f', 't_oid8_to_oid: the restored chunk identifiers fit in an oid');
is( $node->safe_psql(
		'dst', 'SELECT count(*), min(length(val)) FROM t_oid8_to_oid'),
	'3|5000',
	't_oid8_to_oid: the out-of-line values are restored intact');

$node->safe_psql('dst',
	"INSERT INTO t_oid8_to_oid SELECT 4, repeat('c', 5000)");

is(chunk_ids_past_oid_max($node, 'dst', 't_oid8_to_oid'),
	'f', 't_oid8_to_oid: a new identifier fits in an oid');

# A binary upgrade dump carries the type in a separate call, not a reloption.
my $oid8_typoid = $node->safe_psql('src', "SELECT 'oid8'::regtype::oid");
my $bufile = $node->basedir . '/toast_value_type_binary_upgrade.sql';

$node->command_ok(
	[
		'pg_dump', '--binary-upgrade', '--schema-only',
		'--table' => 't_oid8_reset',
		'--file' => $bufile,
		'src'
	],
	'dump the source database for a binary upgrade');

my $budump = slurp_file($bufile);

like(
	$budump,
	qr/binary_upgrade_set_next_toast_chunk_id_typoid\('$oid8_typoid'/,
	't_oid8_reset: a binary upgrade dump carries the type separately');
unlike($budump, qr/toast_value_type/,
	't_oid8_reset: a binary upgrade dump reports no reloption for the type');

done_testing();

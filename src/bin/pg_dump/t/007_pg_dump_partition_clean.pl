# Copyright (c) 2026, PostgreSQL Global Development Group

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $tempdir = PostgreSQL::Test::Utils::tempdir;
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

$node->safe_psql('postgres', 'CREATE DATABASE dump_src');
$node->safe_psql('postgres', 'CREATE DATABASE dump_dst');
$node->safe_psql(
	'dump_src',
	q{
CREATE TABLE p (
    id integer,
    k integer,
    payload text,
    CONSTRAINT p_pkey PRIMARY KEY (id, k),
    CONSTRAINT p_unique UNIQUE (payload, k)
) PARTITION BY LIST (k);
CREATE TABLE p1 PARTITION OF p FOR VALUES IN (1);
CREATE TABLE p2 PARTITION OF p FOR VALUES IN (2);
ALTER TABLE p1 ADD CONSTRAINT p1_local UNIQUE (id);
INSERT INTO p VALUES (1, 1, 'one'), (2, 2, 'two');
});

# A clean dump must drop parent and local constraints, but not inherited ones.
$node->command_ok(
	[
		'pg_dump', '--clean', '--no-sync',
		'--file' => "$tempdir/clean.sql",
		'--dbname' => $node->connstr('dump_src'),
	],
	'plain dump with clean');
my $plain = slurp_file("$tempdir/clean.sql");
like(
	$plain,
	qr/ALTER TABLE ONLY public\.p DROP CONSTRAINT p_pkey;/,
	'plain dump drops parent primary key');
like(
	$plain,
	qr/ALTER TABLE ONLY public\.p DROP CONSTRAINT p_unique;/,
	'plain dump drops parent unique constraint');
unlike(
	$plain,
	qr/DROP CONSTRAINT p[12]_pkey;/,
	'plain dump does not drop inherited primary keys');
unlike(
	$plain,
	qr/DROP CONSTRAINT p[12]_payload_k_key;/,
	'plain dump does not drop inherited unique constraints');
like(
	$plain,
	qr/ALTER TABLE ONLY public\.p1 DROP CONSTRAINT p1_local;/,
	'plain dump drops local constraint on partition');

$node->command_ok(
	[
		'pg_dump', '--format=custom', '--no-sync',
		'--file' => "$tempdir/partition.dump",
		'--dbname' => $node->connstr('dump_src'),
	],
	'custom dump of partition constraints');
$node->command_ok(
	[
		'pg_restore', '--exit-on-error',
		'--dbname' => $node->connstr('dump_dst'),
		"$tempdir/partition.dump",
	],
	'initial restore of partition constraints');

for my $option ('--exit-on-error', '--single-transaction',
	'--transaction-size=2')
{
	$node->command_ok(
		[
			'pg_restore', '--clean', '--if-exists', $option,
			'--dbname' => $node->connstr('dump_dst'),
			"$tempdir/partition.dump",
		],
		"clean restore of partition constraints with $option");
}

is($node->safe_psql('dump_dst', 'SELECT * FROM p ORDER BY id'),
	"1|1|one\n2|2|two", 'data preserved after clean restores');

# Each partition should still inherit both constraints from the parent.
is( $node->safe_psql(
		'dump_dst',
		q{SELECT count(*) FROM pg_constraint
          WHERE conrelid IN ('p'::regclass, 'p1'::regclass, 'p2'::regclass)
            AND contype IN ('p', 'u') AND conparentid <> 0}),
	'4',
	'partition primary keys and unique constraints remain attached');

# Selective clean restore must also drop and recreate a local constraint.
$node->command_ok(
	[
		'pg_restore', '--list',
		'--file' => "$tempdir/toc.list",
		"$tempdir/partition.dump",
	],
	'list partition constraint archive');
my @toc = split /\n/, slurp_file("$tempdir/toc.list");
my @local = grep { / CONSTRAINT public p1 p1_local / } @toc;
is(scalar @local, 1, 'local constraint has an archive entry');
append_to_file("$tempdir/local.list", join("\n", @local) . "\n");
$node->command_ok(
	[
		'pg_restore', '--clean', '--exit-on-error',
		'--use-list' => "$tempdir/local.list",
		'--dbname' => $node->connstr('dump_dst'),
		"$tempdir/partition.dump",
	],
	'selective clean restore of local partition constraint');

# Inherited constraints cannot be dropped if their parent is not selected.
# Check the SQL, since recreating one on an existing table would fail.
my @inherited = grep { / CONSTRAINT public p2 p2_pkey / } @toc;
is(scalar @inherited, 1, 'inherited constraint has an archive entry');
append_to_file("$tempdir/inherited.list", join("\n", @inherited) . "\n");
$node->command_ok(
	[
		'pg_restore', '--clean',
		'--use-list' => "$tempdir/inherited.list",
		'--file' => "$tempdir/inherited.sql",
		"$tempdir/partition.dump",
	],
	'generate selective clean restore of inherited partition constraint');
my $selective = slurp_file("$tempdir/inherited.sql");
unlike(
	$selective,
	qr/DROP CONSTRAINT/,
	'selective restore omits inherited DROP');
like(
	$selective,
	qr/ADD CONSTRAINT p2_pkey PRIMARY KEY/,
	'selective restore retains inherited constraint creation');

done_testing();

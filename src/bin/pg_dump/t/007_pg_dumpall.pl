# Copyright (c) 2021-2026, PostgreSQL Global Development Group

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $tempdir = PostgreSQL::Test::Utils::tempdir;
my $run_db = 'postgres';
my $sep = $windows_os ? "\\" : "/";

# Tablespace locations used by "restore_tablespace" test case.
my $tablespace1 = "${tempdir}${sep}tbl1";
my $tablespace2 = "${tempdir}${sep}tbl2";
mkdir($tablespace1) || die "mkdir $tablespace1 $!";
mkdir($tablespace2) || die "mkdir $tablespace2 $!";

# escape tablespace locations on Windows.
my $tablespace2_orig = $tablespace2;
$tablespace1 = $windows_os ? ($tablespace1 =~ s/\\/\\\\/gr) : $tablespace1;
$tablespace2 = $windows_os ? ($tablespace2 =~ s/\\/\\\\/gr) : $tablespace2;

# Where pg_dumpall will be executed.
my $node = PostgreSQL::Test::Cluster->new('node');
$node->init;
$node->start;


###############################################################
# Definition of the pg_dumpall test cases to run.
#
# Each of these test cases are named and those names are used for fail
# reporting and also to save the dump and restore information needed for the
# test to assert.
#
# The "setup_sql" is a psql valid script that contains SQL commands to execute
# before of actually execute the tests. The setups are all executed before of
# any test execution.
#
# The "dump_cmd" and "restore_cmd" are the commands that will be executed. The
# "restore_cmd" must have the --file flag to save the restore output so that we
# can assert on it.
#
# The "like" and "unlike" is a regexp that is used to match the pg_restore
# output. It must have at least one of then filled per test cases but it also
# can have both. See "excluding_databases" test case for example.
my %pgdumpall_runs = (
	# Test 1: dump and restore roles, including a role's password and its
	# attributes/connection limit.
	restore_roles => {
		setup_sql => '
		CREATE ROLE dumpall WITH ENCRYPTED PASSWORD \'admin\' SUPERUSER;
		CREATE ROLE dumpall2 WITH REPLICATION CONNECTION LIMIT 10;',
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'directory',
			'--file' => "$tempdir/restore_roles",
		],
		restore_cmd => [
			'pg_restore', '-C',
			'--format' => 'directory',
			'--file' => "$tempdir/restore_roles.sql",
			"$tempdir/restore_roles",
		],
		like => qr/
			\s*\QCREATE ROLE dumpall2;\E
			\s*\QALTER ROLE dumpall2 WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN REPLICATION NOBYPASSRLS CONNECTION LIMIT 10;\E
		/xm
	},

	# Test 2: dump and restore a tablespace, including a non-default storage
	# parameter.
	restore_tablespace => {
		setup_sql => "
		CREATE ROLE tap;
		CREATE TABLESPACE tbl1 OWNER tap LOCATION '$tablespace1';
		CREATE TABLESPACE tbl2 OWNER tap LOCATION '$tablespace2' WITH (seq_page_cost=1.0);",
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'directory',
			'--file' => "$tempdir/restore_tablespace",
		],
		restore_cmd => [
			'pg_restore', '-C',
			'--format' => 'directory',
			'--file' => "$tempdir/restore_tablespace.sql",
			"$tempdir/restore_tablespace",
		],
		# Match "E" as optional since it is added on LOCATION when running on
		# Windows.
		like => qr/^
			\n\QCREATE TABLESPACE tbl2 OWNER tap LOCATION \E(?:E)?\Q'$tablespace2_orig';\E
			\n\QALTER TABLESPACE tbl2 SET (seq_page_cost=1.0);\E
		/xm,
	},

	# Test 3: dump and restore GRANTs on a table, sequence, function, schema,
	# database, and role membership.
	restore_grants => {
		setup_sql => "
		CREATE DATABASE tapgrantsdb;
		CREATE SCHEMA private;
		CREATE SEQUENCE serial START 101;
		CREATE FUNCTION fn() RETURNS void AS \$\$
		BEGIN
		END;
		\$\$ LANGUAGE plpgsql;
		CREATE ROLE super;
		CREATE ROLE grant1;
		CREATE ROLE grant2;
		CREATE ROLE grant3;
		CREATE ROLE grant4;
		CREATE ROLE grant5;
		CREATE ROLE grant6;
		CREATE ROLE grant7;
		CREATE ROLE grant8;

		CREATE TABLE t (id int);
		INSERT INTO t VALUES (1), (2), (3), (4);

		GRANT SELECT ON TABLE t TO grant1;
		GRANT INSERT ON TABLE t TO grant2;
		GRANT ALL PRIVILEGES ON TABLE t to grant3;
		GRANT CONNECT, CREATE ON DATABASE tapgrantsdb TO grant4;
		GRANT USAGE, CREATE ON SCHEMA private TO grant5;
		GRANT USAGE, SELECT, UPDATE ON SEQUENCE serial TO grant6;
		GRANT super TO grant7;
		GRANT EXECUTE ON FUNCTION fn() TO grant8;
		",
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'directory',
			'--file' => "$tempdir/restore_grants",
		],
		restore_cmd => [
			'pg_restore', '-C',
			'--format' => 'directory',
			'--file' => "$tempdir/restore_grants.sql",
			"$tempdir/restore_grants",
		],
		like => qr/^
			\n\QGRANT ALL ON SCHEMA private TO grant5;\E
			(.*\n)*
			\n\QGRANT ALL ON FUNCTION public.fn() TO grant8;\E
			(.*\n)*
			\n\QGRANT ALL ON SEQUENCE public.serial TO grant6;\E
			(.*\n)*
			\n\QGRANT SELECT ON TABLE public.t TO grant1;\E
			\n\QGRANT INSERT ON TABLE public.t TO grant2;\E
			\n\QGRANT ALL ON TABLE public.t TO grant3;\E
			(.*\n)*
			\n\QGRANT CREATE,CONNECT ON DATABASE tapgrantsdb TO grant4;\E
		/xm,
	},

	# Test 4: --exclude-database at dump time and at restore time (from the
	# static map.dat database list) each skip their own database.
	excluding_databases => {
		setup_sql => 'CREATE DATABASE db1;
		\c db1
		CREATE TABLE t1 (id int);
		INSERT INTO t1 VALUES (1), (2), (3), (4);
		CREATE TABLE t2 (id int);
		INSERT INTO t2 VALUES (1), (2), (3), (4);

		CREATE DATABASE db2;
		\c db2
		CREATE TABLE t3 (id int);
		INSERT INTO t3 VALUES (1), (2), (3), (4);
		CREATE TABLE t4 (id int);
		INSERT INTO t4 VALUES (1), (2), (3), (4);

		CREATE DATABASE dbex3;
		\c dbex3
		CREATE TABLE t5 (id int);
		INSERT INTO t5 VALUES (1), (2), (3), (4);
		CREATE TABLE t6 (id int);
		INSERT INTO t6 VALUES (1), (2), (3), (4);

		CREATE DATABASE dbex4;
		\c dbex4
		CREATE TABLE t7 (id int);
		INSERT INTO t7 VALUES (1), (2), (3), (4);
		CREATE TABLE t8 (id int);
		INSERT INTO t8 VALUES (1), (2), (3), (4);

		CREATE DATABASE db5;
		\c db5
		CREATE TABLE t9 (id int);
		INSERT INTO t9 VALUES (1), (2), (3), (4);
		CREATE TABLE t10 (id int);
		INSERT INTO t10 VALUES (1), (2), (3), (4);
		',
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'directory',
			'--file' => "$tempdir/excluding_databases",
			'--exclude-database' => 'dbex*',
		],
		restore_cmd => [
			'pg_restore', '-C',
			'--format' => 'directory',
			'--file' => "$tempdir/excluding_databases.sql",
			'--exclude-database' => 'db5',
			"$tempdir/excluding_databases",
		],
		like => qr/^
			\n\QCREATE DATABASE db1\E
			(.*\n)*
			\n\QCREATE TABLE public.t1 (\E
			(.*\n)*
			\n\QCREATE TABLE public.t2 (\E
			(.*\n)*
			\n\QCREATE DATABASE db2\E
			(.*\n)*
			\n\QCREATE TABLE public.t3 (\E
			(.*\n)*
			\n\QCREATE TABLE public.t4 (/xm,
		unlike => qr/^
			\n\QCREATE DATABASE dbex3\E
			(.*\n)*
			\n\QCREATE TABLE public.t5 (\E
			(.*\n)*
			\n\QCREATE TABLE public.t6 (\E
			(.*\n)*
			\n\QCREATE DATABASE dbex4\E
			(.*\n)*
			\n\QCREATE TABLE public.t7 (\E
			(.*\n)*
			\n\QCREATE TABLE public.t8 (\E
			\n\QCREATE DATABASE db5\E
			(.*\n)*
			\n\QCREATE TABLE public.t9 (\E
			(.*\n)*
			\n\QCREATE TABLE public.t10 (\E
		/xm,
	},

	# Test 5: dump and restore using --format=directory.
	format_directory => {
		setup_sql => "CREATE TABLE format_directory(a int, b boolean, c text);
		INSERT INTO format_directory VALUES (1, true, 'name1'), (2, false, 'name2');",
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'directory',
			'--file' => "$tempdir/format_directory",
		],
		restore_cmd => [
			'pg_restore', '-C',
			'--format' => 'directory',
			'--file' => "$tempdir/format_directory.sql",
			"$tempdir/format_directory",
		],
		like => qr/^\n\QCOPY public.format_directory (a, b, c) FROM stdin;/xm
	},

	# Test 6: dump and restore using --format=tar.
	format_tar => {
		setup_sql => "CREATE TABLE format_tar(a int, b boolean, c text);
		INSERT INTO format_tar VALUES (1, false, 'name3'), (2, true, 'name4');",
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'tar',
			'--file' => "$tempdir/format_tar",
		],
		restore_cmd => [
			'pg_restore', '-C',
			'--format' => 'tar',
			'--file' => "$tempdir/format_tar.sql",
			"$tempdir/format_tar",
		],
		like => qr/^\n\QCOPY public.format_tar (a, b, c) FROM stdin;/xm
	},

	# Test 7: dump and restore using --format=custom.
	format_custom => {
		setup_sql => "CREATE TABLE format_custom(a int, b boolean, c text);
		INSERT INTO format_custom VALUES (1, false, 'name5'), (2, true, 'name6');",
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'custom',
			'--file' => "$tempdir/format_custom",
		],
		restore_cmd => [
			'pg_restore', '-C',
			'--format' => 'custom',
			'--file' => "$tempdir/format_custom.sql",
			"$tempdir/format_custom",
		],
		like => qr/^ \n\QCOPY public.format_custom (a, b, c) FROM stdin;/xm
	},

	# Test 8: pg_dumpall --globals-only + pg_restore --globals-only restores
	# just the role, not the accompanying table data.
	dump_globals_only => {
		setup_sql => "CREATE TABLE format_dir(a int, b boolean, c text);
		INSERT INTO format_dir VALUES (1, false, 'name5'), (2, true, 'name6');",
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'directory',
			'--globals-only',
			'--file' => "$tempdir/dump_globals_only",
		],
		restore_cmd => [
			'pg_restore', '-C', '--globals-only',
			'--format' => 'directory',
			'--file' => "$tempdir/dump_globals_only.sql",
			"$tempdir/dump_globals_only",
		],
		like => qr/
            ^\s*\QCREATE ROLE dumpall;\E\s*\n
			/xm
	},

	# Test 9: pg_restore --no-globals restores table data but skips the role.
	restore_no_globals => {
		setup_sql => "CREATE TABLE no_globals_test(a int, b text);
		INSERT INTO no_globals_test VALUES (1, 'hello'), (2, 'world');",
		dump_cmd => [
			'pg_dumpall',
			'--format' => 'directory',
			'--file' => "$tempdir/restore_no_globals",
		],
		restore_cmd => [
			'pg_restore', '-C', '--no-globals',
			'--format' => 'directory',
			'--file' => "$tempdir/restore_no_globals.sql",
			"$tempdir/restore_no_globals",
		],
		like => qr/^\n\QCOPY public.no_globals_test (a, b) FROM stdin;\E/xm,
		unlike => qr/^\QCREATE ROLE dumpall;\E/xm,
	},);

# First execute the setup_sql
foreach my $run (sort keys %pgdumpall_runs)
{
	if ($pgdumpall_runs{$run}->{setup_sql})
	{
		$node->safe_psql($run_db, $pgdumpall_runs{$run}->{setup_sql});
	}
}

# Execute the tests
foreach my $run (sort keys %pgdumpall_runs)
{
	# Create a new target cluster to pg_restore each test case run so that we
	# don't need to take care of the cleanup from the target cluster after each
	# run.
	my $target_node = PostgreSQL::Test::Cluster->new("target_$run");
	$target_node->init;
	$target_node->start;

	# Dumpall from node cluster.
	$node->command_ok(\@{ $pgdumpall_runs{$run}->{dump_cmd} },
		"$run: pg_dumpall runs");

	# Restore the dump on "target_node" cluster.
	my @restore_cmd = (
		@{ $pgdumpall_runs{$run}->{restore_cmd} },
		'--host', $target_node->host, '--port', $target_node->port);

	my ($stdout, $stderr) = run_command(\@restore_cmd);

	# pg_restore --file output file.
	my $output_file = slurp_file("$tempdir/${run}.sql");

	if (   !($pgdumpall_runs{$run}->{like})
		&& !($pgdumpall_runs{$run}->{unlike}))
	{
		die "missing \"like\" or \"unlike\" in test \"$run\"";
	}

	if ($pgdumpall_runs{$run}->{like})
	{
		like($output_file, $pgdumpall_runs{$run}->{like}, "should dump $run");
	}

	if ($pgdumpall_runs{$run}->{unlike})
	{
		unlike(
			$output_file,
			$pgdumpall_runs{$run}->{unlike},
			"should not dump $run");
	}

	$target_node->stop;
	$target_node->clean_node;
}

###############################################################
# Further positive test cases exercising specific behaviors of the
# non-text pg_dumpall archive format.

# Test 10: verify map.dat preamble exists
my $map_dat_content = slurp_file("$tempdir/format_directory/map.dat");
like(
	$map_dat_content,
	qr/^# map\.dat\n.*# This file maps oids to database names/ms,
	'map.dat contains expected preamble');

# Test 11: verify commenting out a line in map.dat skips that database
$node->safe_psql(
	$run_db, 'CREATE DATABASE comment_test_db;
\c comment_test_db
CREATE TABLE comment_test_table (id int);');

$node->command_ok(
	[
		'pg_dumpall',
		'--format' => 'directory',
		'--file' => "$tempdir/comment_test",
	],
	'pg_dumpall for comment test');

# Modify map.dat to comment out the comment_test_db entry
my $map_content = slurp_file("$tempdir/comment_test/map.dat");
$map_content =~ s/^(\d+ comment_test_db)$/# $1/m;
open(my $fh, '>', "$tempdir/comment_test/map.dat")
  or die "Cannot open map.dat: $!";
print $fh $map_content;
close($fh);

# Create a target node and restore - commented db should be skipped
my $target_comment = PostgreSQL::Test::Cluster->new("target_comment");
$target_comment->init;
$target_comment->start;

$node->command_ok(
	[
		'pg_restore', '-C',
		'--format' => 'directory',
		'--file' => "$tempdir/comment_test_restore.sql",
		'--host', $target_comment->host,
		'--port', $target_comment->port,
		"$tempdir/comment_test",
	],
	'pg_restore with commented out database in map.dat');

my $restore_output = slurp_file("$tempdir/comment_test_restore.sql");
unlike(
	$restore_output,
	qr/CREATE DATABASE comment_test_db/,
	'commented out database in map.dat is not restored');

# Test 12: --clean without --if-exists should not add IF EXISTS (no
# auto-implication).
$node->command_ok(
	[
		'pg_restore', '-C',
		'--format' => 'custom',
		'--clean',
		'--file' => "$tempdir/clean_test.sql",
		"$tempdir/format_custom",
	],
	'pg_restore with --clean on pg_dumpall archive');

my $clean_output = slurp_file("$tempdir/clean_test.sql");
like(
	$clean_output,
	qr/DROP ROLE(?! IF EXISTS)/,
	'--clean without --if-exists: DROP ROLE without IF EXISTS in output');
like(
	$clean_output,
	qr/DROP TABLESPACE(?! IF EXISTS)/,
	'--clean without --if-exists: DROP TABLESPACE without IF EXISTS in output'
);
like(
	$clean_output,
	qr/DROP DATABASE(?! IF EXISTS)/,
	'--clean without --if-exists: DROP DATABASE without IF EXISTS in output');

# Test 13: --clean --if-exists adds IF EXISTS to all object types.
$node->command_ok(
	[
		'pg_restore', '-C',
		'--format' => 'custom',
		'--clean',
		'--if-exists',
		'--file' => "$tempdir/clean_if_exists_test.sql",
		"$tempdir/format_custom",
	],
	'pg_restore with --clean --if-exists on pg_dumpall archive');

my $clean_if_exists_output = slurp_file("$tempdir/clean_if_exists_test.sql");
like(
	$clean_if_exists_output,
	qr/DROP ROLE IF EXISTS/,
	'--clean --if-exists: DROP ROLE IF EXISTS in output');
like(
	$clean_if_exists_output,
	qr/DROP TABLESPACE IF EXISTS/,
	'--clean --if-exists: DROP TABLESPACE IF EXISTS in output');
like(
	$clean_if_exists_output,
	qr/DROP DATABASE IF EXISTS/,
	'--clean --if-exists: DROP DATABASE IF EXISTS in output');

# Test 14: live (-d) restore of a full archive into a fresh cluster, twice,
# with --clean --if-exists the second time, must drop and recreate the
# role/tablespace/database rather than silently skip the drops.
my $liverestore_tablespace = "$tempdir/liverestore_tbl";
mkdir $liverestore_tablespace
  or die "unable to create $liverestore_tablespace";

$node->safe_psql(
	$run_db, "
	CREATE ROLE liverestore_role;
	CREATE TABLESPACE liverestore_tbl OWNER liverestore_role LOCATION '$liverestore_tablespace';
	CREATE DATABASE liverestore_db TABLESPACE liverestore_tbl;
	");

$node->command_ok(
	[ 'pg_dumpall', '--format' => 'custom', '--file' => "$tempdir/liverestore" ],
	'pg_dumpall for live restore test');

# Free the tablespace path for the target cluster below to reuse.
$node->safe_psql($run_db,
	"DROP DATABASE liverestore_db; DROP TABLESPACE liverestore_tbl;");

my $target_liverestore = PostgreSQL::Test::Cluster->new("target_liverestore");
$target_liverestore->init;
$target_liverestore->start;

my @liverestore_cmd = (
	'pg_restore', '-C',
	'--format' => 'custom',
	'-d' => 'postgres',
	'--host' => $target_liverestore->host,
	'--port' => $target_liverestore->port,
	"$tempdir/liverestore");

my $liverestore_exists_re = qr/
	\Qrole "liverestore_role" already exists\E |
	\Qtablespace "liverestore_tbl" already exists\E |
	\Qdatabase "liverestore_db" already exists\E
/x;

sub check_liverestore_objects
{
	my ($label) = @_;
	is($target_liverestore->safe_psql('postgres',
			"SELECT count(*) FROM pg_roles WHERE rolname = 'liverestore_role'"),
		1, "$label: role present");
	is($target_liverestore->safe_psql('postgres',
			"SELECT count(*) FROM pg_tablespace WHERE spcname = 'liverestore_tbl'"),
		1, "$label: tablespace present");
	is($target_liverestore->safe_psql('postgres',
			"SELECT count(*) FROM pg_database WHERE datname = 'liverestore_db'"),
		1, "$label: database present");
}

my (undef, $liverestore_stderr1) = run_command(\@liverestore_cmd);
unlike($liverestore_stderr1, $liverestore_exists_re,
	'first live restore: no unexpected "already exists" errors');
check_liverestore_objects('first live restore');

my (undef, $liverestore_stderr2) =
  run_command([ @liverestore_cmd, '--clean', '--if-exists' ]);
unlike($liverestore_stderr2, $liverestore_exists_re,
	'second live restore: no unexpected "already exists" errors');
like(
	$liverestore_stderr2,
	qr/errors ignored on restore of global objects: \d+/,
	'second live restore: errors on global objects are counted');
check_liverestore_objects('second live restore');

$target_liverestore->stop;
$target_liverestore->clean_node;

# Test 15: --schema must still restore global objects (roles, tablespaces),
# even though they have no schema and would otherwise be excluded by it.
$node->command_ok(
	[
		'pg_restore', '-C',
		'--format' => 'custom',
		'--schema' => 'nonexistent_schema',
		'--file' => "$tempdir/schema_filter_test.sql",
		"$tempdir/format_custom",
	],
	'pg_restore with --schema on pg_dumpall archive');

my $schema_filter_output = slurp_file("$tempdir/schema_filter_test.sql");
like($schema_filter_output, qr/CREATE ROLE dumpall2;/,
	'--schema filter: global ROLE objects are still restored');
like($schema_filter_output, qr/CREATE TABLESPACE tbl2 /,
	'--schema filter: global TABLESPACE objects are still restored');
unlike($schema_filter_output, qr/CREATE TABLE public\.format_custom/,
	'--schema filter: non-matching schema-scoped objects are excluded');

# Test 16: --exclude-database over a live connection (-d) exercises the SQL
# pattern-matching path, distinct from the static map.dat-parsing path
# used when restoring to a script file with no connection.
my $target_liveexclude = PostgreSQL::Test::Cluster->new("target_liveexclude");
$target_liveexclude->init;
$target_liveexclude->start;

run_command(
	[
		'pg_restore', '-C',
		'--format' => 'directory',
		'-d' => 'postgres',
		'--host' => $target_liveexclude->host,
		'--port' => $target_liveexclude->port,
		'--exclude-database' => 'db2',
		"$tempdir/excluding_databases",
	]);

is($target_liveexclude->safe_psql('postgres',
		"SELECT count(*) FROM pg_database WHERE datname = 'db1'"),
	1, 'live --exclude-database: non-excluded database was restored');
is($target_liveexclude->safe_psql('postgres',
		"SELECT count(*) FROM pg_database WHERE datname = 'db2'"),
	0, 'live --exclude-database: excluded database was not restored');

$target_liveexclude->stop;
$target_liveexclude->clean_node;

# Test 17: parallel (-j) restore, combined with --no-tablespaces.
my $target_parallel = PostgreSQL::Test::Cluster->new("target_parallel");
$target_parallel->init;
$target_parallel->start;

run_command(
	[
		'pg_restore', '-C',
		'--format' => 'directory',
		'-d' => 'postgres',
		'--host' => $target_parallel->host,
		'--port' => $target_parallel->port,
		'--jobs' => 2,
		'--no-tablespaces',
		"$tempdir/excluding_databases",
	]);

is($target_parallel->safe_psql('postgres',
		"SELECT count(*) FROM pg_database WHERE datname = 'db1'"),
	1, 'parallel restore: database was created');
is($target_parallel->safe_psql('postgres',
		"SELECT count(*) FROM pg_tablespace WHERE spcname = 'tbl2'"),
	0, 'parallel restore with --no-tablespaces: tablespace was not created');

$target_parallel->stop;
$target_parallel->clean_node;

# Test 17a: with --clean, each database must be dropped exactly once: by
# the globals archive, ahead of the roles and tablespaces it may depend on,
# and not again by its own per-database archive.
$node->command_ok(
	[
		'pg_restore', '-C',
		'--format' => 'directory',
		'--clean',
		'--file' => "$tempdir/clean_once.sql",
		"$tempdir/excluding_databases",
	],
	'pg_restore --clean on pg_dumpall archive');

my $clean_once_output = slurp_file("$tempdir/clean_once.sql");
my $db1_drops = () = $clean_once_output =~ /^DROP DATABASE db1;$/mg;
is($db1_drops, 1, '--clean: database is dropped exactly once');

# Test 17b: --clean together with --exclude-database must not drop the
# excluded database.
my $target_cleanexclude =
  PostgreSQL::Test::Cluster->new("target_cleanexclude");
$target_cleanexclude->init;
$target_cleanexclude->start;

my @cleanexclude_cmd = (
	'pg_restore', '-C',
	'--format' => 'directory',
	'-d' => 'postgres',
	'--host' => $target_cleanexclude->host,
	'--port' => $target_cleanexclude->port,
	"$tempdir/excluding_databases");

run_command(\@cleanexclude_cmd);
$target_cleanexclude->safe_psql('db2', 'CREATE TABLE cleanexclude_marker ()');

my (undef, $cleanexclude_stderr) = run_command(
	[ @cleanexclude_cmd, '--clean', '--exclude-database' => 'db2' ]);
unlike(
	$cleanexclude_stderr,
	qr/\Qdatabase "db1" does not exist\E/,
	'--clean: no error from dropping a database twice');
is( $target_cleanexclude->safe_psql(
		'db2',
		"SELECT count(*) FROM pg_class WHERE relname = 'cleanexclude_marker'"),
	1,
	'--clean --exclude-database: excluded database was not dropped');
is( $target_cleanexclude->safe_psql('postgres',
		"SELECT count(*) FROM pg_database WHERE datname = 'db1'"),
	1,
	'--clean --exclude-database: non-excluded database was recreated');

$target_cleanexclude->stop;
$target_cleanexclude->clean_node;

# Test 17c: with --clean, the database pg_restore is connected to (-d) is
# dropped and recreated from another connection, rather than failing with
# "cannot drop the currently open database".
my $target_anchor = PostgreSQL::Test::Cluster->new("target_anchor");
$target_anchor->init;
$target_anchor->start;

my @anchor_cmd = (
	'pg_restore', '-C',
	'--format' => 'directory',
	'--host' => $target_anchor->host,
	'--port' => $target_anchor->port,
	"$tempdir/excluding_databases");

run_command([ @anchor_cmd, '-d' => 'postgres' ]);

foreach my $anchor_db ('postgres', 'db1')
{
	$target_anchor->safe_psql($anchor_db, 'CREATE TABLE anchor_marker ()');

	my (undef, $anchor_stderr) = run_command(
		[ @anchor_cmd, '--clean', '--if-exists', '-d' => $anchor_db ]);
	unlike(
		$anchor_stderr,
		qr/cannot drop the currently open database/,
		"--clean -d $anchor_db: connected database is not dropped from its own connection"
	);
	is( $target_anchor->safe_psql(
			$anchor_db,
			"SELECT count(*) FROM pg_class WHERE relname = 'anchor_marker'"),
		0,
		"--clean -d $anchor_db: connected database was recreated");
}

$target_anchor->stop;
$target_anchor->clean_node;

###############################################################
# Negative test cases: dump using pg_dumpall, then check that pg_restore
# rejects invalid option combinations against the resulting archive.

# Test 18: report an error when -C is not used in pg_restore with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom",
		'--format' => 'custom',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: option -C\/--create must be specified when restoring an archive created by pg_dumpall\E/,
	'When -C is not used in pg_restore with dump of pg_dumpall');

# Test 19: report an error when \l/--list option is used with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--list',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: option -l\/--list cannot be used when restoring an archive created by pg_dumpall\E/,
	'When --list is used in pg_restore with dump of pg_dumpall');

# Test 20: report an error when -L/--use-list option is used with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--use-list' => 'use',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: option -L\/--use-list cannot be used when restoring an archive created by pg_dumpall\E/,
	'When -L/--use-list is used in pg_restore with dump of pg_dumpall');

# Test 21: report an error when --strict-names option is used with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--strict-names',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: option --strict-names cannot be used when restoring an archive created by pg_dumpall\E/,
	'When --strict-names is used in pg_restore with dump of pg_dumpall');

# Test 22: report an error when --clean and -g/--globals-only are used in pg_restore with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--clean',
		'--globals-only',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: options --clean and -g\/--globals-only cannot be used together when restoring an archive created by pg_dumpall\E/,
	'When --clean and -g/--globals-only are used in pg_restore with dump of pg_dumpall'
);

# Test 23: report an error when non-exist database is given with -d option
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'-d' => 'dbpq',
	],
	qr/\QFATAL:  database "dbpq" does not exist\E/,
	'When non-existent database is given with -d option in pg_restore with dump of pg_dumpall'
);

# Test 24: report an error when --no-schema is used with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--no-schema',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: option --no-schema cannot be used when restoring an archive created by pg_dumpall\E/,
	'When --no-schema is used in pg_restore with dump of pg_dumpall');

# Test 25: report an error when --data-only is used with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--data-only',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: option -a\/--data-only cannot be used when restoring an archive created by pg_dumpall\E/,
	'When --data-only is used in pg_restore with dump of pg_dumpall');

# Test 26: report an error when --statistics-only is used with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--statistics-only',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: option --statistics-only cannot be used when restoring an archive created by pg_dumpall\E/,
	'When --statistics-only is used in pg_restore with dump of pg_dumpall');

# Test 27: report an error when --section excludes pre-data with dump of pg_dumpall
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--section' => 'post-data',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: option --section cannot exclude pre-data when restoring a pg_dumpall archive\E/,
	'When --section=post-data is used in pg_restore with dump of pg_dumpall');

# Test 28: report an error when --globals-only and --data-only are used together
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--globals-only',
		'--data-only',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: options -a\/--data-only and -g\/--globals-only cannot be used together\E/,
	'When --globals-only and --data-only are used together');

# Test 29: report an error when --globals-only and --schema-only are used together
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--globals-only',
		'--schema-only',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: options -g\/--globals-only and -s\/--schema-only cannot be used together\E/,
	'When --globals-only and --schema-only are used together');

# Test 30: report an error when --globals-only and --statistics-only are used together
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--globals-only',
		'--statistics-only',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: options -g\/--globals-only and --statistics-only cannot be used together\E/,
	'When --globals-only and --statistics-only are used together');

# Test 31: report an error when --globals-only and --statistics are used together
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--globals-only',
		'--statistics',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: options --statistics and -g\/--globals-only cannot be used together\E/,
	'When --globals-only and --statistics are used together');

# Test 32: report an error when --globals-only and --exit-on-error are used together
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--globals-only',
		'--exit-on-error',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: options --exit-on-error and -g\/--globals-only cannot be used together\E/,
	'When --globals-only and --exit-on-error are used together');

# Test 33: report an error when --globals-only and --single-transaction are used together
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--globals-only',
		'--single-transaction',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: options -g\/--globals-only and -1\/--single-transaction cannot be used together\E/,
	'When --globals-only and --single-transaction are used together');

# Test 34: report an error when --globals-only and --transaction-size are used together
$node->command_fails_like(
	[
		'pg_restore',
		"$tempdir/format_custom", '-C',
		'--format' => 'custom',
		'--globals-only',
		'--transaction-size' => '100',
		'--file' => "$tempdir/error_test.sql",
	],
	qr/\Qpg_restore: error: options -g\/--globals-only and --transaction-size cannot be used together\E/,
	'When --globals-only and --transaction-size are used together');

$node->stop('fast');

done_testing();

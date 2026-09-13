# Cross-check pg_get_role_ddl()/pg_get_tablespace_ddl()/pg_get_database_ddl()
# against pg_dumpall's own output for the same objects, per Andres Freund's
# review comment that nothing currently guards against the two diverging:
# https://postgr.es/m/ia2gifmcdsiunj3j6i4yumnnzru45nvet4mxtydb6nodwrvkhe@qkd7lzlxsrht
use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

$node->safe_psql(
	'postgres', q{
	SET allow_in_place_tablespaces = true;
	CREATE ROLE regress_ddl_crosscheck_role LOGIN CREATEDB
	  CONNECTION LIMIT 3 PASSWORD 'crosscheck_pw'
	  VALID UNTIL '2035-06-15 12:00:00+00';
	ALTER ROLE regress_ddl_crosscheck_role SET work_mem = '17MB';
	CREATE TABLESPACE regress_ddl_crosscheck_tblspc
	  OWNER regress_ddl_crosscheck_role LOCATION ''
	  WITH (random_page_cost = 2.25);
	CREATE DATABASE regress_ddl_crosscheck_db
	  OWNER regress_ddl_crosscheck_role
	  TABLESPACE regress_ddl_crosscheck_tblspc
	  CONNECTION LIMIT 7;
	ALTER DATABASE regress_ddl_crosscheck_db SET work_mem = '31MB';
	});

# Normalize: collapse whitespace, drop the trailing semicolon, and sort
# each statement's own whitespace-split tokens so clause/token order
# (which the two implementations aren't guaranteed to agree on) doesn't
# cause spurious failures. Returns an arrayref, sorted, one entry per
# input statement.
sub normalize_statements
{
	my (@statements) = @_;
	my @out;

	for my $stmt (@statements)
	{
		$stmt =~ s/^\s+|\s+$//g;
		$stmt =~ s/;$//;
		$stmt =~ s/\s+/ /g;
		next if $stmt eq '';
		push @out, join(' ', sort split(/\s+/, $stmt));
	}
	return [ sort @out ];
}

# --- pg_dumpall globals (roles + tablespaces) ---
# connstr() gives pg_dumpall the right host/port without needing PGHOST/
# PGPORT in the environment.
my ($globals_out, $globals_err);
run_log(
	[ 'pg_dumpall', '--globals-only', '-d', $node->connstr('postgres') ],
	'>', \$globals_out, '2>', \$globals_err)
  or die "pg_dumpall --globals-only failed: $globals_err";

# Anchor on statement type, not just a substring match on the object's
# name: a plain name match also catches pg_dumpall's "-- User Config
# "role"" comment headers, and statements for other objects that merely
# reference this one (e.g. the tablespace's "OWNER regress_..._role"
# clause on its CREATE TABLESPACE line).
my @dumpall_role_lines = grep {
	/regress_ddl_crosscheck_role/ && /^(CREATE|ALTER) ROLE/
} split(/\n/, $globals_out);
my @dumpall_tblspc_lines = grep {
	/regress_ddl_crosscheck_tblspc/ && /^(CREATE|ALTER) TABLESPACE/
} split(/\n/, $globals_out);

my $our_role_ddl = $node->safe_psql('postgres',
	q{SELECT string_agg(pg_get_role_ddl, E'\n') FROM
	  pg_get_role_ddl('regress_ddl_crosscheck_role')});
my $our_tblspc_ddl = $node->safe_psql('postgres',
	q{SELECT string_agg(pg_get_tablespace_ddl, E'\n') FROM
	  pg_get_tablespace_ddl('regress_ddl_crosscheck_tblspc')});

is_deeply(
	normalize_statements(split(/\n/, $our_role_ddl)),
	normalize_statements(@dumpall_role_lines),
	'pg_get_role_ddl matches pg_dumpall --globals-only, token-for-token');

is_deeply(
	normalize_statements(split(/\n/, $our_tblspc_ddl)),
	normalize_statements(@dumpall_tblspc_lines),
	'pg_get_tablespace_ddl matches pg_dumpall --globals-only, token-for-token');

# --- pg_dump --create (database-level CREATE DATABASE + ALTER DATABASE) ---
my ($dbdump_out, $dbdump_err);
run_log(
	[
		'pg_dump', '--create', '--schema-only',
		'-d', $node->connstr('regress_ddl_crosscheck_db'),
	],
	'>', \$dbdump_out, '2>', \$dbdump_err)
  or die "pg_dump --create failed: $dbdump_err";

my @pgdump_db_lines =
  grep { /regress_ddl_crosscheck_db/ && /^(CREATE|ALTER) DATABASE/ }
  split(/\n/, $dbdump_out);

my $our_db_ddl = $node->safe_psql('postgres',
	q{SELECT string_agg(pg_get_database_ddl, E'\n') FROM
	  pg_get_database_ddl('regress_ddl_crosscheck_db')});

is_deeply(
	normalize_statements(split(/\n/, $our_db_ddl)),
	normalize_statements(@pgdump_db_lines),
	'pg_get_database_ddl matches pg_dump --create, token-for-token');

$node->stop;
done_testing();

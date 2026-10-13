/*-------------------------------------------------------------------------
 *
 * pg_dumpall.c
 *	  pg_dumpall dumps all databases and global objects (roles and
 *	  tablespaces) from a PostgreSQL cluster.
 *
 *	  For text format output, globals are written directly and pg_dump is
 *	  invoked for each database, with all output going to stdout or a file.
 *
 *	  For non-text formats (custom, directory, tar), a directory is created
 *	  containing a toc.glo file with global objects, a map.dat file mapping
 *	  database OIDs to names, and a databases/ subdirectory with individual
 *	  pg_dump archives for each database.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/bin/pg_dump/pg_dumpall.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres_fe.h"

#include <time.h>
#include <unistd.h>

#include "catalog/pg_authid_d.h"
#include "common/connect.h"
#include "common/file_perm.h"
#include "common/file_utils.h"
#include "common/hashfn_unstable.h"
#include "common/logging.h"
#include "common/string.h"
#include "connectdb.h"
#include "dumputils.h"
#include "fe_utils/option_utils.h"
#include "fe_utils/string_utils.h"
#include "filter.h"
#include "getopt_long.h"
#include "pg_backup_archiver.h"

/* version string we expect back from pg_dump */
#define PGDUMP_VERSIONSTR "pg_dump (PostgreSQL) " PG_VERSION "\n"

typedef struct
{
	uint32		status;
	uint32		hashval;
	char	   *rolename;
} RoleNameEntry;

#define SH_PREFIX	rolename
#define SH_ELEMENT_TYPE	RoleNameEntry
#define SH_KEY_TYPE	char *
#define SH_KEY		rolename
#define SH_HASH_KEY(tb, key)	hash_string(key)
#define SH_EQUAL(tb, a, b)		(strcmp(a, b) == 0)
#define SH_STORE_HASH
#define SH_GET_HASH(tb, a)		(a)->hashval
#define SH_SCOPE	static inline
#define SH_RAW_ALLOCATOR	pg_malloc0
#define SH_DECLARE
#define SH_DEFINE
#include "lib/simplehash.h"

static void help(void);

static void dumpRoles(PGconn *conn);
static void dumpRoleMembership(PGconn *conn);
static void dumpRoleGUCPrivs(PGconn *conn);
static void dumpTablespaces(PGconn *conn);
static void dumpUserConfig(PGconn *conn, const char *username);
static void dropDatabases(PGconn *conn);
static void dumpDatabases(PGconn *conn);
static void dumpTimestamp(const char *msg);
static int	runPgDump(const char *dbname, const char *create_opts, char *dbfile);
static void buildShSecLabels(PGconn *conn,
							 const char *catalog_name, Oid objectId,
							 const char *objtype, const char *objname,
							 PQExpBuffer buffer);
static void executeCommand(PGconn *conn, const char *query);
static void check_for_invalid_global_names(PGconn *conn,
										   SimpleStringList *excluded_names);
static void expand_dbname_patterns(PGconn *conn, SimpleStringList *patterns,
								   SimpleStringList *names);
static void read_dumpall_filters(const char *filename, SimpleStringList *pattern);
static ArchiveFormat parseDumpFormat(const char *format);
static DumpId createDumpId(void);

static char pg_dump_bin[MAXPGPATH];
static PQExpBuffer pgdumpopts;
static const char *connstr = "";
static bool output_clean = false;
static bool data_only = false;
static bool skip_acls = false;
static bool verbose = false;
static bool dosync = true;

static int	binary_upgrade = 0;
static int	column_inserts = 0;
static int	disable_dollar_quoting = 0;
static int	disable_triggers = 0;
static int	if_exists = 0;
static int	inserts = 0;
static int	no_table_access_method = 0;
static int	no_tablespaces = 0;
static int	use_setsessauth = 0;
static int	no_comments = 0;
static int	no_policies = 0;
static int	no_publications = 0;
static int	no_security_labels = 0;
static int	no_data = 0;
static int	no_schema = 0;
static int	no_statistics = 0;
static int	no_subscriptions = 0;
static int	no_toast_compression = 0;
static int	no_unlogged_table_data = 0;
static int	no_role_passwords = 0;
static int	with_statistics = 0;
static int	server_version;
static int	load_via_partition_root = 0;
static int	on_conflict_do_nothing = 0;
static int	statistics_only = 0;
static int	sequence_data = 0;

static char role_catalog[10];
#define PG_AUTHID "pg_authid"
#define PG_ROLES  "pg_roles "

static FILE *OPF;
static char *filename = NULL;

static SimpleStringList database_exclude_patterns = {NULL, NULL};
static SimpleStringList database_exclude_names = {NULL, NULL};

static char *restrict_key;
static Archive *fout = NULL;
static DumpId lastDumpId = 0;
static ArchiveFormat archDumpFormat = archNull;
static const CatalogId nilCatalogId = {0, 0};

int
main(int argc, char *argv[])
{
	static struct option long_options[] = {
		{"data-only", no_argument, NULL, 'a'},
		{"clean", no_argument, NULL, 'c'},
		{"encoding", required_argument, NULL, 'E'},
		{"file", required_argument, NULL, 'f'},
		{"globals-only", no_argument, NULL, 'g'},
		{"host", required_argument, NULL, 'h'},
		{"dbname", required_argument, NULL, 'd'},
		{"database", required_argument, NULL, 'l'},
		{"no-owner", no_argument, NULL, 'O'},
		{"port", required_argument, NULL, 'p'},
		{"roles-only", no_argument, NULL, 'r'},
		{"schema-only", no_argument, NULL, 's'},
		{"superuser", required_argument, NULL, 'S'},
		{"tablespaces-only", no_argument, NULL, 't'},
		{"username", required_argument, NULL, 'U'},
		{"verbose", no_argument, NULL, 'v'},
		{"no-password", no_argument, NULL, 'w'},
		{"password", no_argument, NULL, 'W'},
		{"no-privileges", no_argument, NULL, 'x'},
		{"no-acl", no_argument, NULL, 'x'},
		{"format", required_argument, NULL, 'F'},

		/*
		 * the following options don't have an equivalent short option letter
		 */
		{"attribute-inserts", no_argument, &column_inserts, 1},
		{"binary-upgrade", no_argument, &binary_upgrade, 1},
		{"column-inserts", no_argument, &column_inserts, 1},
		{"disable-dollar-quoting", no_argument, &disable_dollar_quoting, 1},
		{"disable-triggers", no_argument, &disable_triggers, 1},
		{"exclude-database", required_argument, NULL, 6},
		{"extra-float-digits", required_argument, NULL, 5},
		{"if-exists", no_argument, &if_exists, 1},
		{"inserts", no_argument, &inserts, 1},
		{"lock-wait-timeout", required_argument, NULL, 2},
		{"no-table-access-method", no_argument, &no_table_access_method, 1},
		{"no-tablespaces", no_argument, &no_tablespaces, 1},
		{"quote-all-identifiers", no_argument, &quote_all_identifiers, 1},
		{"load-via-partition-root", no_argument, &load_via_partition_root, 1},
		{"role", required_argument, NULL, 3},
		{"use-set-session-authorization", no_argument, &use_setsessauth, 1},
		{"no-comments", no_argument, &no_comments, 1},
		{"no-data", no_argument, &no_data, 1},
		{"no-policies", no_argument, &no_policies, 1},
		{"no-publications", no_argument, &no_publications, 1},
		{"no-role-passwords", no_argument, &no_role_passwords, 1},
		{"no-schema", no_argument, &no_schema, 1},
		{"no-security-labels", no_argument, &no_security_labels, 1},
		{"no-subscriptions", no_argument, &no_subscriptions, 1},
		{"no-statistics", no_argument, &no_statistics, 1},
		{"no-sync", no_argument, NULL, 4},
		{"no-toast-compression", no_argument, &no_toast_compression, 1},
		{"no-unlogged-table-data", no_argument, &no_unlogged_table_data, 1},
		{"on-conflict-do-nothing", no_argument, &on_conflict_do_nothing, 1},
		{"rows-per-insert", required_argument, NULL, 7},
		{"statistics", no_argument, &with_statistics, 1},
		{"statistics-only", no_argument, &statistics_only, 1},
		{"filter", required_argument, NULL, 8},
		{"sequence-data", no_argument, &sequence_data, 1},
		{"restrict-key", required_argument, NULL, 9},

		{NULL, 0, NULL, 0}
	};

	char	   *pghost = NULL;
	char	   *pgport = NULL;
	char	   *pguser = NULL;
	char	   *pgdb = NULL;
	char	   *use_role = NULL;
	const char *dumpencoding = NULL;
	const char *format_name = "p";
	trivalue	prompt_password = TRI_DEFAULT;
	bool		globals_only = false;
	bool		roles_only = false;
	bool		schema_only = false;
	bool		tablespaces_only = false;
	PGconn	   *conn;
	int			encoding;
	int			c,
				ret;
	int			optindex;
	DumpOptions dopt;
	PQExpBuffer qry;
	const char *encname;
	pg_compress_specification compression_spec = {0};

	pg_logging_init(argv[0]);
	pg_logging_set_level(PG_LOG_WARNING);
	set_pglocale_pgservice(argv[0], PG_TEXTDOMAIN("pg_dump"));
	progname = get_progname(argv[0]);

	if (argc > 1)
	{
		if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-?") == 0)
		{
			help();
			exit_nicely(0);
		}
		if (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-V") == 0)
		{
			puts("pg_dumpall (PostgreSQL) " PG_VERSION);
			exit_nicely(0);
		}
	}

	if ((ret = find_other_exec(argv[0], "pg_dump", PGDUMP_VERSIONSTR,
							   pg_dump_bin)) < 0)
	{
		char		full_path[MAXPGPATH];

		if (find_my_exec(argv[0], full_path) < 0)
			strlcpy(full_path, progname, sizeof(full_path));

		if (ret == -1)
			pg_fatal("program \"%s\" is needed by %s but was not found in the same directory as \"%s\"",
					 "pg_dump", progname, full_path);
		else
			pg_fatal("program \"%s\" was found by \"%s\" but was not the same version as %s",
					 "pg_dump", full_path, progname);
	}

	pgdumpopts = createPQExpBuffer();
	InitDumpOptions(&dopt);

	while ((c = getopt_long(argc, argv, "acd:E:f:F:gh:l:Op:rsS:tU:vwWx", long_options, &optindex)) != -1)
	{
		switch (c)
		{
			case 'a':
				data_only = true;
				appendPQExpBufferStr(pgdumpopts, " -a");
				break;

			case 'c':
				output_clean = true;
				break;

			case 'd':
				connstr = pg_strdup(optarg);
				break;

			case 'E':
				dumpencoding = pg_strdup(optarg);
				appendPQExpBufferStr(pgdumpopts, " -E ");
				appendShellString(pgdumpopts, optarg);
				break;

			case 'f':
				/* Not put into pgdumpopts; runPgDump() needs its own -f. */
				filename = pg_strdup(optarg);
				break;

			case 'F':
				format_name = pg_strdup(optarg);
				break;

			case 'g':
				globals_only = true;
				break;

			case 'h':
				pghost = pg_strdup(optarg);
				break;

			case 'l':
				pgdb = pg_strdup(optarg);
				break;

			case 'O':
				appendPQExpBufferStr(pgdumpopts, " -O");
				break;

			case 'p':
				pgport = pg_strdup(optarg);
				break;

			case 'r':
				roles_only = true;
				break;

			case 's':
				schema_only = true;
				appendPQExpBufferStr(pgdumpopts, " -s");
				break;

			case 'S':
				appendPQExpBufferStr(pgdumpopts, " -S ");
				appendShellString(pgdumpopts, optarg);
				break;

			case 't':
				tablespaces_only = true;
				break;

			case 'U':
				pguser = pg_strdup(optarg);
				dopt.cparams.username = pg_strdup(optarg);
				break;

			case 'v':
				verbose = true;
				pg_logging_increase_verbosity();
				appendPQExpBufferStr(pgdumpopts, " -v");
				break;

			case 'w':
				prompt_password = TRI_NO;
				appendPQExpBufferStr(pgdumpopts, " -w");
				break;

			case 'W':
				prompt_password = TRI_YES;
				appendPQExpBufferStr(pgdumpopts, " -W");
				break;

			case 'x':
				skip_acls = true;
				appendPQExpBufferStr(pgdumpopts, " -x");
				break;

			case 0:
				break;

			case 2:
				appendPQExpBufferStr(pgdumpopts, " --lock-wait-timeout ");
				appendShellString(pgdumpopts, optarg);
				break;

			case 3:
				use_role = pg_strdup(optarg);
				appendPQExpBufferStr(pgdumpopts, " --role ");
				appendShellString(pgdumpopts, use_role);
				break;

			case 4:
				dosync = false;
				appendPQExpBufferStr(pgdumpopts, " --no-sync");
				break;

			case 5:
				appendPQExpBufferStr(pgdumpopts, " --extra-float-digits ");
				appendShellString(pgdumpopts, optarg);
				break;

			case 6:
				simple_string_list_append(&database_exclude_patterns, optarg);
				break;

			case 7:
				appendPQExpBufferStr(pgdumpopts, " --rows-per-insert ");
				appendShellString(pgdumpopts, optarg);
				break;

			case 8:
				read_dumpall_filters(optarg, &database_exclude_patterns);
				break;

			case 9:
				restrict_key = pg_strdup(optarg);
				appendPQExpBufferStr(pgdumpopts, " --restrict-key ");
				appendShellString(pgdumpopts, optarg);
				break;

			default:
				/* getopt_long already emitted a complaint */
				pg_log_error_hint("Try \"%s --help\" for more information.", progname);
				exit_nicely(1);
		}
	}

	/* Complain if any arguments remain */
	if (optind < argc)
	{
		pg_log_error("too many command-line arguments (first is \"%s\")",
					 argv[optind]);
		pg_log_error_hint("Try \"%s --help\" for more information.", progname);
		exit_nicely(1);
	}

	/* --exclude-database is incompatible with global *-only options */
	check_mut_excl_opts(database_exclude_patterns.head != NULL, "--exclude-database",
						globals_only, "-g/--globals-only",
						roles_only, "-r/--roles-only",
						tablespaces_only, "-t/--tablespaces-only");

	/* *-only options are incompatible with each other */
	check_mut_excl_opts(data_only, "-a/--data-only",
						globals_only, "-g/--globals-only",
						roles_only, "-r/--roles-only",
						schema_only, "-s/--schema-only",
						statistics_only, "--statistics-only",
						tablespaces_only, "-t/--tablespaces-only");

	/* --no-* and *-only for same thing are incompatible */
	check_mut_excl_opts(data_only, "-a/--data-only",
						no_data, "--no-data");
	check_mut_excl_opts(schema_only, "-s/--schema-only",
						no_schema, "--no-schema");
	check_mut_excl_opts(statistics_only, "--statistics-only",
						no_statistics, "--no-statistics");

	/* --statistics and --no-statistics are incompatible */
	check_mut_excl_opts(with_statistics, "--statistics",
						no_statistics, "--no-statistics");

	/* --statistics is incompatible with *-only (except --statistics-only) */
	check_mut_excl_opts(with_statistics, "--statistics",
						data_only, "-a/--data-only",
						globals_only, "-g/--globals-only",
						roles_only, "-r/--roles-only",
						schema_only, "-s/--schema-only",
						tablespaces_only, "-t/--tablespaces-only");

	/* --clean and --data-only are incompatible */
	check_mut_excl_opts(output_clean, "-c/--clean",
						data_only, "-a/--data-only");

	if (if_exists && !output_clean)
		pg_fatal("option %s requires option %s",
				 "--if-exists", "-c/--clean");

	/* Get format for dump. */
	archDumpFormat = parseDumpFormat(format_name);

	/*
	 * If a non-plain format is specified, a file name is also required as the
	 * path to the main directory.
	 */
	if (archDumpFormat != archNull &&
		(!filename || strcmp(filename, "") == 0))
	{
		pg_log_error("option %s=d|c|t requires option %s",
					 "-F/--format", "-f/--file");
		pg_log_error_hint("Try \"%s --help\" for more information.", progname);
		exit_nicely(1);
	}

	/* restrict-key is only supported with --format=plain */
	if (archDumpFormat != archNull && restrict_key)
		pg_fatal("option %s can only be used with %s=plain",
				 "--restrict-key", "--format");

	/* --clean and -g/--globals-only cannot be used together in non-text dump */
	if (archDumpFormat != archNull && output_clean && globals_only)
		pg_fatal("options %s and %s cannot be used together in non-text dump",
				 "--clean", "-g/--globals-only");

	/*
	 * If password values are not required in the dump, switch to using
	 * pg_roles which is equally useful, just more likely to have unrestricted
	 * access than pg_authid.
	 */
	if (no_role_passwords)
		sprintf(role_catalog, "%s", PG_ROLES);
	else
		sprintf(role_catalog, "%s", PG_AUTHID);

	/* Add long options to the pg_dump argument list */
	if (binary_upgrade)
		appendPQExpBufferStr(pgdumpopts, " --binary-upgrade");
	if (column_inserts)
		appendPQExpBufferStr(pgdumpopts, " --column-inserts");
	if (disable_dollar_quoting)
		appendPQExpBufferStr(pgdumpopts, " --disable-dollar-quoting");
	if (disable_triggers)
		appendPQExpBufferStr(pgdumpopts, " --disable-triggers");
	if (inserts)
		appendPQExpBufferStr(pgdumpopts, " --inserts");
	if (no_table_access_method)
		appendPQExpBufferStr(pgdumpopts, " --no-table-access-method");
	if (no_tablespaces)
		appendPQExpBufferStr(pgdumpopts, " --no-tablespaces");
	if (quote_all_identifiers)
		appendPQExpBufferStr(pgdumpopts, " --quote-all-identifiers");
	if (load_via_partition_root)
		appendPQExpBufferStr(pgdumpopts, " --load-via-partition-root");
	if (use_setsessauth)
		appendPQExpBufferStr(pgdumpopts, " --use-set-session-authorization");
	if (no_comments)
		appendPQExpBufferStr(pgdumpopts, " --no-comments");
	if (no_data)
		appendPQExpBufferStr(pgdumpopts, " --no-data");
	if (no_policies)
		appendPQExpBufferStr(pgdumpopts, " --no-policies");
	if (no_publications)
		appendPQExpBufferStr(pgdumpopts, " --no-publications");
	if (no_security_labels)
		appendPQExpBufferStr(pgdumpopts, " --no-security-labels");
	if (no_schema)
		appendPQExpBufferStr(pgdumpopts, " --no-schema");
	if (no_statistics)
		appendPQExpBufferStr(pgdumpopts, " --no-statistics");
	if (no_subscriptions)
		appendPQExpBufferStr(pgdumpopts, " --no-subscriptions");
	if (no_toast_compression)
		appendPQExpBufferStr(pgdumpopts, " --no-toast-compression");
	if (no_unlogged_table_data)
		appendPQExpBufferStr(pgdumpopts, " --no-unlogged-table-data");
	if (with_statistics)
		appendPQExpBufferStr(pgdumpopts, " --statistics");
	if (on_conflict_do_nothing)
		appendPQExpBufferStr(pgdumpopts, " --on-conflict-do-nothing");
	if (statistics_only)
		appendPQExpBufferStr(pgdumpopts, " --statistics-only");
	if (sequence_data)
		appendPQExpBufferStr(pgdumpopts, " --sequence-data");

	/*
	 * Open the output file if required, otherwise use stdout.  If required,
	 * then create new directory.
	 */
	if (archDumpFormat != archNull)
	{
		Assert(filename);

		/* Create new directory or accept the empty existing directory. */
		create_or_open_dir(filename);
	}
	else if (filename)
	{
		OPF = fopen(filename, PG_BINARY_W);
		if (!OPF)
			pg_fatal("could not open output file \"%s\": %m",
					 filename);
		fclose(OPF);

		/*
		 * Reopen in append mode, so that our writes always go to the end of
		 * the file even after the archiver or pg_dump has appended to it.
		 * Flushing OPF is then enough; we needn't close and reopen it around
		 * those writes.
		 */
		OPF = fopen(filename, PG_BINARY_A);
		if (!OPF)
			pg_fatal("could not open output file \"%s\": %m", filename);
	}
	else
		OPF = stdout;

	/*
	 * If you don't provide a restrict key, one will be appointed for you.
	 */
	if (!restrict_key)
		restrict_key = generate_restrict_key();
	if (!restrict_key)
		pg_fatal("could not generate restrict key");
	if (!valid_restrict_key(restrict_key))
		pg_fatal("invalid restrict key");

	/*
	 * If there was a database specified on the command line, use that,
	 * otherwise try to connect to database "postgres", and failing that
	 * "template1".
	 */
	if (pgdb)
	{
		conn = ConnectDatabase(pgdb, connstr, pghost, pgport, pguser,
							   prompt_password, false,
							   progname, &connstr, &server_version, NULL, NULL);

		if (!conn)
			pg_fatal("could not connect to database \"%s\"", pgdb);
	}
	else
	{
		conn = ConnectDatabase("postgres", connstr, pghost, pgport, pguser,
							   prompt_password, false,
							   progname, &connstr, &server_version, NULL, NULL);
		if (!conn)
			conn = ConnectDatabase("template1", connstr, pghost, pgport, pguser,
								   prompt_password, true,
								   progname, &connstr, &server_version, NULL, NULL);

		if (!conn)
		{
			pg_log_error("could not connect to databases \"postgres\" or \"template1\"\n"
						 "Please specify an alternative database.");
			pg_log_error_hint("Try \"%s --help\" for more information.", progname);
			exit_nicely(1);
		}
	}

	/*
	 * Get a list of database names that match the exclude patterns
	 */
	expand_dbname_patterns(conn, &database_exclude_patterns,
						   &database_exclude_names);

	/*
	 * Set the client encoding if requested.
	 */
	if (dumpencoding)
	{
		if (PQsetClientEncoding(conn, dumpencoding) < 0)
			pg_fatal("invalid client encoding \"%s\" specified",
					 dumpencoding);
	}

	/*
	 * Force standard_conforming_strings on, just in case we are dumping from
	 * an old server that has it disabled.  Without this, literals in views,
	 * expressions, etc, would be incorrect for modern servers.
	 */
	executeCommand(conn, "SET standard_conforming_strings = on");

	/*
	 * Get the active encoding, so we know how to escape strings.
	 */
	encoding = PQclientEncoding(conn);
	setFmtEncoding(encoding);

	/* Set the role if requested */
	if (use_role)
	{
		PQExpBuffer query = createPQExpBuffer();

		appendPQExpBuffer(query, "SET ROLE %s", fmtId(use_role));
		executeCommand(conn, query->data);
		destroyPQExpBuffer(query);
	}

	/* Force quoting of all identifiers if requested. */
	if (quote_all_identifiers)
		executeCommand(conn, "SET quote_all_identifiers = true");

	/* Write the plain-text dump header. */
	if (archDumpFormat == archNull)
	{
		fprintf(OPF, "--\n-- PostgreSQL database cluster dump\n--\n\n");

		if (verbose)
			dumpTimestamp("Started on");

		fflush(OPF);
	}

	/*
	 * Check that no global object names contain newlines or carriage returns,
	 * which would break the map.dat file format.  This is only needed for
	 * servers older than v19, which started prohibiting such names.
	 */
	if (server_version < 190000 && archDumpFormat != archNull)
		check_for_invalid_global_names(conn, &database_exclude_names);

	/*
	 * Create an archive for the global objects.  For non-plain formats it is
	 * written to toc.glo; for plain format it is an in-memory archive that is
	 * written to the output file by RestoreArchive() below, ahead of the
	 * per-database pg_dump output.
	 */
	if (archDumpFormat != archNull)
	{
		char		global_path[MAXPGPATH];

		snprintf(global_path, MAXPGPATH, "%s/toc.glo", filename);

		fout = CreateArchive(global_path, archCustom, compression_spec,
							 dosync, archModeWrite, NULL, DATA_DIR_SYNC_METHOD_FSYNC);
	}
	else
		fout = CreateArchive(filename, archNull, compression_spec,
							 dosync, archModeWrite, NULL, DATA_DIR_SYNC_METHOD_FSYNC);

	fout->std_strings = true;
	fout->encoding = encoding;

	/* Make dump options accessible right away */
	SetArchiveOptions(fout, &dopt, NULL);

	((ArchiveHandle *) fout)->public.numWorkers = 1;

	/* Register the cleanup hook */
	on_exit_close_archive(fout);

	/*
	 * Let the archiver know how noisy to be.  For plain format, the archive
	 * is only being written out, so don't let the archiver report what it
	 * would be doing to a database.
	 */
	if (archDumpFormat != archNull)
		fout->verbose = verbose;

	/*
	 * Mark this as pg_dumpall's globals archive.  When it's written out as
	 * SQL, the archiver then leaves out its own pg_dump header and footer (we
	 * print our own), and makes sure the script can write to the target
	 * cluster.
	 */
	((ArchiveHandle *) fout)->dumpallGlobals = true;

	/*
	 * Don't output TOC entry comments when dumping globals; they're purely
	 * informational and just add noise ahead of the SQL.
	 */
	((ArchiveHandle *) fout)->noTocComments = 1;

	/*
	 * We allow the server to be back to 9.2, and up to any minor release of
	 * our own major version.  (See also version check in pg_dumpall.c.)
	 */
	fout->minRemoteVersion = 90200;
	fout->maxRemoteVersion = (PG_VERSION_NUM / 100) * 100 + 99;
	fout->numWorkers = 1;

	qry = createPQExpBuffer();

	/* Put the correct encoding into the archive */
	encname = pg_encoding_to_char(encoding);

	appendPQExpBufferStr(qry, "SET client_encoding = ");
	appendStringLiteralAH(qry, encname, fout);
	appendPQExpBufferStr(qry, ";\n");
	ArchiveEntry(fout,
				 nilCatalogId,	/* catalog ID */
				 createDumpId(),	/* dump ID */
				 ARCHIVE_OPTS(.tag = "ENCODING",
							  .description = "ENCODING",
							  .section = SECTION_PRE_DATA,
							  .createStmt = qry->data));
	resetPQExpBuffer(qry);

	/* Put the correct escape string behavior into the archive. */
	appendPQExpBufferStr(qry, "SET standard_conforming_strings = 'on';\n");
	ArchiveEntry(fout,
				 nilCatalogId,	/* catalog ID */
				 createDumpId(),	/* dump ID */
				 ARCHIVE_OPTS(.tag = "STDSTRINGS",
							  .description = "STDSTRINGS",
							  .section = SECTION_PRE_DATA,
							  .createStmt = qry->data));
	destroyPQExpBuffer(qry);

	/*
	 * Each role, tablespace, and database gets its drop statement attached to
	 * its archive entry, regardless of --clean.  The archiver's drop pass
	 * decides when the archive is written out (plain format, per --clean) or
	 * restored (other formats, per pg_restore's own --clean) whether to run
	 * them.  It runs them in reverse order, so databases are dropped before
	 * the tablespaces and roles they depend on.
	 */
	if (!data_only && !statistics_only && !no_schema)
	{
		if (!tablespaces_only)
		{
			/* Dump roles (users) */
			dumpRoles(conn);

			/* Dump role memberships */
			dumpRoleMembership(conn);

			/* Dump role GUC privileges */
			if (server_version >= 150000 && !skip_acls)
				dumpRoleGUCPrivs(conn);
		}

		/* Dump tablespaces */
		if (!roles_only && !no_tablespaces)
			dumpTablespaces(conn);

		if (!globals_only && !roles_only && !tablespaces_only)
			dropDatabases(conn);
	}

	if (archDumpFormat == archNull)
	{
		RestoreOptions *ropt = NewRestoreOptions();

		ropt->filename = filename;
		ropt->dropSchema = output_clean;
		ropt->if_exists = if_exists;
		ropt->restrict_key = restrict_key;
		SetArchiveOptions(fout, &dopt, ropt);
		ProcessArchiveRestoreOptions(fout);

		/* write out all global objects before any database */
		RestoreArchive(fout, true);
		CloseArchive(fout);
	}

	if (!globals_only && !roles_only && !tablespaces_only)
		dumpDatabases(conn);

	PQfinish(conn);

	if (archDumpFormat == archNull)
	{
		if (verbose)
			dumpTimestamp("Completed on");
		fprintf(OPF, "--\n-- PostgreSQL database cluster dump complete\n--\n\n");

		if (filename)
		{
			fclose(OPF);

			/* sync the resulting file, errors are not fatal */
			if (dosync)
				(void) fsync_fname(filename, false);
		}
	}
	else
	{
		RestoreOptions *ropt;

		ropt = NewRestoreOptions();
		SetArchiveOptions(fout, &dopt, ropt);

		/* Mark which entries should be output */
		ProcessArchiveRestoreOptions(fout);
		CloseArchive(fout);
	}

	exit_nicely(0);
}


static void
help(void)
{
	printf(_("%s exports a PostgreSQL database cluster as an SQL script or to other formats.\n\n"), progname);
	printf(_("Usage:\n"));
	printf(_("  %s [OPTION]...\n"), progname);

	printf(_("\nGeneral options:\n"));
	printf(_("  -f, --file=FILENAME          output file name\n"));
	printf(_("  -F, --format=c|d|t|p         output file format (custom, directory, tar,\n"
			 "                               plain text (default))\n"));
	printf(_("  -v, --verbose                verbose mode\n"));
	printf(_("  -V, --version                output version information, then exit\n"));
	printf(_("  --lock-wait-timeout=TIMEOUT  fail after waiting TIMEOUT for a table lock\n"));
	printf(_("  -?, --help                   show this help, then exit\n"));
	printf(_("\nOptions controlling the output content:\n"));
	printf(_("  -a, --data-only              dump only the data, not the schema or statistics\n"));
	printf(_("  -c, --clean                  clean (drop) databases before recreating\n"));
	printf(_("  -E, --encoding=ENCODING      dump the data in encoding ENCODING\n"));
	printf(_("  -g, --globals-only           dump only global objects, no databases\n"));
	printf(_("  -O, --no-owner               skip restoration of object ownership\n"));
	printf(_("  -r, --roles-only             dump only roles, no databases or tablespaces\n"));
	printf(_("  -s, --schema-only            dump only the schema, no data or statistics\n"));
	printf(_("  -S, --superuser=NAME         superuser user name to use in the dump\n"));
	printf(_("  -t, --tablespaces-only       dump only tablespaces, no databases or roles\n"));
	printf(_("  -x, --no-privileges          do not dump privileges (grant/revoke)\n"));
	printf(_("  --binary-upgrade             for use by upgrade utilities only\n"));
	printf(_("  --column-inserts             dump data as INSERT commands with column names\n"));
	printf(_("  --disable-dollar-quoting     disable dollar quoting, use SQL standard quoting\n"));
	printf(_("  --disable-triggers           disable triggers during data-only restore\n"));
	printf(_("  --exclude-database=PATTERN   exclude databases whose name matches PATTERN\n"));
	printf(_("  --extra-float-digits=NUM     override default setting for extra_float_digits\n"));
	printf(_("  --filter=FILENAME            exclude databases based on expressions in FILENAME\n"));
	printf(_("  --if-exists                  use IF EXISTS when dropping objects\n"));
	printf(_("  --inserts                    dump data as INSERT commands, rather than COPY\n"));
	printf(_("  --load-via-partition-root    load partitions via the root table\n"));
	printf(_("  --no-comments                do not dump comment commands\n"));
	printf(_("  --no-data                    do not dump data\n"));
	printf(_("  --no-policies                do not dump row security policies\n"));
	printf(_("  --no-publications            do not dump publications\n"));
	printf(_("  --no-role-passwords          do not dump passwords for roles\n"));
	printf(_("  --no-schema                  do not dump schema\n"));
	printf(_("  --no-security-labels         do not dump security label assignments\n"));
	printf(_("  --no-statistics              do not dump statistics\n"));
	printf(_("  --no-subscriptions           do not dump subscriptions\n"));
	printf(_("  --no-sync                    do not wait for changes to be written safely to disk\n"));
	printf(_("  --no-table-access-method     do not dump table access methods\n"));
	printf(_("  --no-tablespaces             do not dump tablespace assignments\n"));
	printf(_("  --no-toast-compression       do not dump TOAST compression methods\n"));
	printf(_("  --no-unlogged-table-data     do not dump unlogged table data\n"));
	printf(_("  --on-conflict-do-nothing     add ON CONFLICT DO NOTHING to INSERT commands\n"));
	printf(_("  --quote-all-identifiers      quote all identifiers, even if not key words\n"));
	printf(_("  --restrict-key=RESTRICT_KEY  use provided string as psql \\restrict key\n"));
	printf(_("  --rows-per-insert=NROWS      number of rows per INSERT; implies --inserts\n"));
	printf(_("  --sequence-data              include sequence data in dump\n"));
	printf(_("  --statistics                 dump the statistics\n"));
	printf(_("  --statistics-only            dump only the statistics, not schema or data\n"));
	printf(_("  --use-set-session-authorization\n"
			 "                               use SET SESSION AUTHORIZATION commands instead of\n"
			 "                               ALTER OWNER commands to set ownership\n"));

	printf(_("\nConnection options:\n"));
	printf(_("  -d, --dbname=CONNSTR     connect using connection string\n"));
	printf(_("  -h, --host=HOSTNAME      database server host or socket directory\n"));
	printf(_("  -l, --database=DBNAME    alternative default database\n"));
	printf(_("  -p, --port=PORT          database server port number\n"));
	printf(_("  -U, --username=NAME      connect as specified database user\n"));
	printf(_("  -w, --no-password        never prompt for password\n"));
	printf(_("  -W, --password           force password prompt (should happen automatically)\n"));
	printf(_("  --role=ROLENAME          do SET ROLE before dump\n"));

	printf(_("\nIf -f/--file is not used, then the SQL script will be written to the standard\n"
			 "output.\n\n"));
	printf(_("Report bugs to <%s>.\n"), PACKAGE_BUGREPORT);
	printf(_("%s home page: <%s>\n"), PACKAGE_NAME, PACKAGE_URL);
}

/*
 * Drop and dump roles.
 */
static void
dumpRoles(PGconn *conn)
{
	PQExpBuffer buf = createPQExpBuffer();
	PQExpBuffer delQry = createPQExpBuffer();
	PQExpBuffer comment_buf = createPQExpBuffer();
	PQExpBuffer seclabel_buf = createPQExpBuffer();
	PGresult   *res;
	int			i_oid,
				i_rolname,
				i_rolsuper,
				i_rolinherit,
				i_rolcreaterole,
				i_rolcreatedb,
				i_rolcanlogin,
				i_rolconnlimit,
				i_rolpassword,
				i_rolvaliduntil,
				i_rolreplication,
				i_rolbypassrls,
				i_rolcomment,
				i_is_current_user;
	int			i;

	/*
	 * Notes: rolconfig is dumped later, and pg_authid must be used for
	 * extracting rolcomment regardless of role_catalog.
	 */
	printfPQExpBuffer(buf,
					  "SELECT oid, rolname, rolsuper, rolinherit, "
					  "rolcreaterole, rolcreatedb, "
					  "rolcanlogin, rolconnlimit, rolpassword, "
					  "rolvaliduntil, rolreplication, rolbypassrls, "
					  "pg_catalog.shobj_description(oid, 'pg_authid') as rolcomment, "
					  "rolname = current_user AS is_current_user "
					  "FROM %s "
					  "WHERE rolname !~ '^pg_' "
					  "ORDER BY 2", role_catalog);

	res = executeQuery(conn, buf->data);

	i_oid = PQfnumber(res, "oid");
	i_rolname = PQfnumber(res, "rolname");
	i_rolsuper = PQfnumber(res, "rolsuper");
	i_rolinherit = PQfnumber(res, "rolinherit");
	i_rolcreaterole = PQfnumber(res, "rolcreaterole");
	i_rolcreatedb = PQfnumber(res, "rolcreatedb");
	i_rolcanlogin = PQfnumber(res, "rolcanlogin");
	i_rolconnlimit = PQfnumber(res, "rolconnlimit");
	i_rolpassword = PQfnumber(res, "rolpassword");
	i_rolvaliduntil = PQfnumber(res, "rolvaliduntil");
	i_rolreplication = PQfnumber(res, "rolreplication");
	i_rolbypassrls = PQfnumber(res, "rolbypassrls");
	i_rolcomment = PQfnumber(res, "rolcomment");
	i_is_current_user = PQfnumber(res, "is_current_user");

	for (i = 0; i < PQntuples(res); i++)
	{
		const char *rolename;
		Oid			auth_oid;
		char	   *tag;
		DumpId		roleDumpId;

		auth_oid = atooid(PQgetvalue(res, i, i_oid));
		rolename = PQgetvalue(res, i, i_rolname);

		if (strncmp(rolename, "pg_", 3) == 0)
		{
			pg_log_warning("role name starting with \"pg_\" skipped (%s)",
						   rolename);
			continue;
		}

		resetPQExpBuffer(buf);
		resetPQExpBuffer(delQry);
		resetPQExpBuffer(comment_buf);
		resetPQExpBuffer(seclabel_buf);

		appendPQExpBuffer(delQry, "DROP ROLE %s;\n", fmtId(rolename));

		if (binary_upgrade)
		{
			appendPQExpBufferStr(buf, "\n-- For binary upgrade, must preserve pg_authid.oid\n");
			appendPQExpBuffer(buf,
							  "SELECT pg_catalog.binary_upgrade_set_next_pg_authid_oid('%u'::pg_catalog.oid);\n\n",
							  auth_oid);
		}

		/*
		 * We dump CREATE ROLE followed by ALTER ROLE to ensure that the role
		 * will acquire the right properties even if it already exists (ie, it
		 * won't hurt for the CREATE to fail).  This is particularly important
		 * for the role we are connected as, since even with --clean we will
		 * have failed to drop it.  binary_upgrade cannot generate any errors,
		 * so we assume the current role is already created.
		 */
		if (!binary_upgrade ||
			strcmp(PQgetvalue(res, i, i_is_current_user), "f") == 0)
			appendPQExpBuffer(buf, "CREATE ROLE %s;\n", fmtId(rolename));
		appendPQExpBuffer(buf, "ALTER ROLE %s WITH", fmtId(rolename));

		if (strcmp(PQgetvalue(res, i, i_rolsuper), "t") == 0)
			appendPQExpBufferStr(buf, " SUPERUSER");
		else
			appendPQExpBufferStr(buf, " NOSUPERUSER");

		if (strcmp(PQgetvalue(res, i, i_rolinherit), "t") == 0)
			appendPQExpBufferStr(buf, " INHERIT");
		else
			appendPQExpBufferStr(buf, " NOINHERIT");

		if (strcmp(PQgetvalue(res, i, i_rolcreaterole), "t") == 0)
			appendPQExpBufferStr(buf, " CREATEROLE");
		else
			appendPQExpBufferStr(buf, " NOCREATEROLE");

		if (strcmp(PQgetvalue(res, i, i_rolcreatedb), "t") == 0)
			appendPQExpBufferStr(buf, " CREATEDB");
		else
			appendPQExpBufferStr(buf, " NOCREATEDB");

		if (strcmp(PQgetvalue(res, i, i_rolcanlogin), "t") == 0)
			appendPQExpBufferStr(buf, " LOGIN");
		else
			appendPQExpBufferStr(buf, " NOLOGIN");

		if (strcmp(PQgetvalue(res, i, i_rolreplication), "t") == 0)
			appendPQExpBufferStr(buf, " REPLICATION");
		else
			appendPQExpBufferStr(buf, " NOREPLICATION");

		if (strcmp(PQgetvalue(res, i, i_rolbypassrls), "t") == 0)
			appendPQExpBufferStr(buf, " BYPASSRLS");
		else
			appendPQExpBufferStr(buf, " NOBYPASSRLS");

		if (strcmp(PQgetvalue(res, i, i_rolconnlimit), "-1") != 0)
			appendPQExpBuffer(buf, " CONNECTION LIMIT %s",
							  PQgetvalue(res, i, i_rolconnlimit));


		if (!PQgetisnull(res, i, i_rolpassword) && !no_role_passwords)
		{
			appendPQExpBufferStr(buf, " PASSWORD ");
			appendStringLiteralConn(buf, PQgetvalue(res, i, i_rolpassword), conn);
		}

		if (!PQgetisnull(res, i, i_rolvaliduntil))
			appendPQExpBuffer(buf, " VALID UNTIL '%s'",
							  PQgetvalue(res, i, i_rolvaliduntil));

		appendPQExpBufferStr(buf, ";\n");

		if (!no_comments && !PQgetisnull(res, i, i_rolcomment))
		{
			appendPQExpBuffer(comment_buf, "COMMENT ON ROLE %s IS ", fmtId(rolename));
			appendStringLiteralConn(comment_buf, PQgetvalue(res, i, i_rolcomment), conn);
			appendPQExpBufferStr(comment_buf, ";\n");
		}

		if (!no_security_labels)
			buildShSecLabels(conn, "pg_authid", auth_oid,
							 "ROLE", rolename,
							 seclabel_buf);

		tag = psprintf("ROLE %s", fmtId(rolename));
		roleDumpId = createDumpId();

		ArchiveEntry(fout,
					 nilCatalogId,	/* catalog ID */
					 roleDumpId,	/* dump ID */
					 ARCHIVE_OPTS(.tag = tag,
								  .description = "ROLE",
								  .section = SECTION_PRE_DATA,
								  .createStmt = buf->data,
								  .dropStmt = delQry->data));
		if (comment_buf->data[0] != '\0')
			ArchiveEntry(fout,
						 nilCatalogId,	/* catalog ID */
						 createDumpId(),	/* dump ID */
						 ARCHIVE_OPTS(.tag = tag,
									  .description = "COMMENT",
									  .section = SECTION_PRE_DATA,
									  .createStmt = comment_buf->data,
									  .deps = &roleDumpId,
									  .nDeps = 1));

		if (seclabel_buf->data[0] != '\0')
			ArchiveEntry(fout,
						 nilCatalogId,	/* catalog ID */
						 createDumpId(),	/* dump ID */
						 ARCHIVE_OPTS(.tag = tag,
									  .description = "SECURITY LABEL",
									  .section = SECTION_PRE_DATA,
									  .createStmt = seclabel_buf->data,
									  .deps = &roleDumpId,
									  .nDeps = 1));

		free(tag);
	}

	/*
	 * Dump configuration settings for roles after all roles have been dumped.
	 * We do it this way because config settings for roles could mention the
	 * names of other roles.
	 */
	for (i = 0; i < PQntuples(res); i++)
		dumpUserConfig(conn, PQgetvalue(res, i, i_rolname));

	PQclear(res);
	destroyPQExpBuffer(buf);
	destroyPQExpBuffer(delQry);
	destroyPQExpBuffer(comment_buf);
	destroyPQExpBuffer(seclabel_buf);
}


/*
 * Dump role memberships.
 *
 * Note: we expect dumpRoles already created all the roles, but there is
 * no membership yet.
 */
static void
dumpRoleMembership(PGconn *conn)
{
	PQExpBuffer buf = createPQExpBuffer();
	PQExpBuffer querybuf = createPQExpBuffer();
	PQExpBuffer optbuf = createPQExpBuffer();
	PGresult   *res;
	int			start = 0,
				end,
				total;
	bool		dump_grantors;
	bool		dump_grant_options;
	int			i_role;
	int			i_member;
	int			i_grantor;
	int			i_roleid;
	int			i_memberid;
	int			i_grantorid;
	int			i_admin_option;
	int			i_inherit_option;
	int			i_set_option;

	/*
	 * Previous versions of PostgreSQL didn't used to track the grantor very
	 * carefully in the backend, and the grantor could be any user even if
	 * they didn't have ADMIN OPTION on the role, or a user that no longer
	 * existed. To avoid dump and restore failures, don't dump the grantor
	 * when talking to an old server version.
	 *
	 * Also, in older versions the roleid and/or member could be role OIDs
	 * that no longer exist.  If we find such cases, print a warning and skip
	 * the entry.
	 */
	dump_grantors = (server_version >= 160000);

	/*
	 * Previous versions of PostgreSQL also did not have grant-level options.
	 */
	dump_grant_options = (server_version >= 160000);

	/* Generate and execute query. */
	printfPQExpBuffer(buf, "SELECT ur.rolname AS role, "
					  "um.rolname AS member, "
					  "ug.rolname AS grantor, "
					  "a.roleid AS roleid, "
					  "a.member AS memberid, "
					  "a.grantor AS grantorid, "
					  "a.admin_option");
	if (dump_grant_options)
		appendPQExpBufferStr(buf, ", a.inherit_option, a.set_option");
	appendPQExpBuffer(buf, " FROM pg_auth_members a "
					  "LEFT JOIN %s ur on ur.oid = a.roleid "
					  "LEFT JOIN %s um on um.oid = a.member "
					  "LEFT JOIN %s ug on ug.oid = a.grantor "
					  "WHERE NOT (ur.rolname ~ '^pg_' AND um.rolname ~ '^pg_')"
					  "ORDER BY 1,2,3", role_catalog, role_catalog, role_catalog);
	res = executeQuery(conn, buf->data);
	i_role = PQfnumber(res, "role");
	i_member = PQfnumber(res, "member");
	i_grantor = PQfnumber(res, "grantor");
	i_roleid = PQfnumber(res, "roleid");
	i_memberid = PQfnumber(res, "memberid");
	i_grantorid = PQfnumber(res, "grantorid");
	i_admin_option = PQfnumber(res, "admin_option");
	i_inherit_option = PQfnumber(res, "inherit_option");
	i_set_option = PQfnumber(res, "set_option");

	/*
	 * We can't dump these GRANT commands in arbitrary order, because a role
	 * that is named as a grantor must already have ADMIN OPTION on the role
	 * for which it is granting permissions, except for the bootstrap
	 * superuser, who can always be named as the grantor.
	 *
	 * We handle this by considering these grants role by role. For each role,
	 * we initially consider the only allowable grantor to be the bootstrap
	 * superuser. Every time we grant ADMIN OPTION on the role to some user,
	 * that user also becomes an allowable grantor. We make repeated passes
	 * over the grants for the role, each time dumping those whose grantors
	 * are allowable and which we haven't done yet. Eventually this should let
	 * us dump all the grants.
	 */
	total = PQntuples(res);
	while (start < total)
	{
		char	   *role = PQgetvalue(res, start, i_role);
		int			i;
		bool	   *done;
		int			remaining;
		int			prev_remaining = 0;
		rolename_hash *ht;

		/* If we hit a null roleid, we're done (nulls sort to the end). */
		if (PQgetisnull(res, start, i_role))
		{
			/* translator: %s represents a numeric role OID */
			pg_log_warning("ignoring role grant for missing role with OID %s",
						   PQgetvalue(res, start, i_roleid));
			break;
		}

		/* All memberships for a single role should be adjacent. */
		for (end = start; end < total; ++end)
		{
			char	   *otherrole;

			otherrole = PQgetvalue(res, end, i_role);
			if (strcmp(role, otherrole) != 0)
				break;
		}

		remaining = end - start;
		done = pg_malloc0_array(bool, remaining);

		/*
		 * We use a hashtable to track the member names that have been granted
		 * admin option.  Usually a hashtable is overkill, but sometimes not.
		 */
		ht = rolename_create(remaining, NULL);

		/*
		 * Make repeated passes over the grants for this role until all have
		 * been dumped.
		 */
		while (remaining > 0)
		{
			/*
			 * We should make progress on every iteration, because a notional
			 * graph whose vertices are grants and whose edges point from
			 * grantors to members should be connected and acyclic. If we fail
			 * to make progress, either we or the server have messed up.
			 */
			if (remaining == prev_remaining)
			{
				pg_log_error("could not find a legal dump ordering for memberships in role \"%s\"",
							 role);
				PQfinish(conn);
				exit_nicely(1);
			}
			prev_remaining = remaining;

			/* Make one pass over the grants for this role. */
			for (i = start; i < end; ++i)
			{
				char	   *member;
				char	   *grantorid;
				char	   *grantor = NULL;
				bool		dump_this_grantor = dump_grantors;
				char	   *set_option = "true";
				char	   *admin_option;
				bool		found;

				/* If we already did this grant, don't do it again. */
				if (done[i - start])
					continue;

				/* Complain about, then ignore, entries for unknown members. */
				if (PQgetisnull(res, i, i_member))
				{
					/* translator: %s represents a numeric role OID */
					pg_log_warning("ignoring role grant to missing role with OID %s",
								   PQgetvalue(res, i, i_memberid));
					done[i - start] = true;
					--remaining;
					continue;
				}
				member = PQgetvalue(res, i, i_member);

				/* If the grantor is unknown, complain and dump without it. */
				grantorid = PQgetvalue(res, i, i_grantorid);
				if (dump_this_grantor)
				{
					if (PQgetisnull(res, i, i_grantor))
					{
						/* translator: %s represents a numeric role OID */
						pg_log_warning("grant of role \"%s\" to \"%s\" has invalid grantor OID %s",
									   role, member, grantorid);
						pg_log_warning_detail("This grant will be dumped without GRANTED BY.");
						dump_this_grantor = false;
					}
					else
						grantor = PQgetvalue(res, i, i_grantor);
				}

				admin_option = PQgetvalue(res, i, i_admin_option);
				if (dump_grant_options)
					set_option = PQgetvalue(res, i, i_set_option);

				/*
				 * If we're not dumping the grantor or if the grantor is the
				 * bootstrap superuser, it's fine to dump this now. Otherwise,
				 * it's got to be someone who has already been granted ADMIN
				 * OPTION.
				 */
				if (dump_this_grantor &&
					atooid(grantorid) != BOOTSTRAP_SUPERUSERID &&
					rolename_lookup(ht, grantor) == NULL)
					continue;

				/* Remember that we did this so that we don't do it again. */
				done[i - start] = true;
				--remaining;

				/*
				 * If ADMIN OPTION is being granted, remember that grants
				 * listing this member as the grantor can now be dumped.
				 */
				if (*admin_option == 't')
					rolename_insert(ht, member, &found);

				/* Generate the actual GRANT statement. */
				resetPQExpBuffer(optbuf);
				resetPQExpBuffer(querybuf);
				appendPQExpBuffer(querybuf, "GRANT %s", fmtId(role));
				appendPQExpBuffer(querybuf, " TO %s", fmtId(member));
				if (*admin_option == 't')
					appendPQExpBufferStr(optbuf, "ADMIN OPTION");
				if (dump_grant_options)
				{
					char	   *inherit_option;

					if (optbuf->data[0] != '\0')
						appendPQExpBufferStr(optbuf, ", ");
					inherit_option = PQgetvalue(res, i, i_inherit_option);
					appendPQExpBuffer(optbuf, "INHERIT %s",
									  *inherit_option == 't' ?
									  "TRUE" : "FALSE");
				}
				if (*set_option != 't')
				{
					if (optbuf->data[0] != '\0')
						appendPQExpBufferStr(optbuf, ", ");
					appendPQExpBufferStr(optbuf, "SET FALSE");
				}
				if (optbuf->data[0] != '\0')
					appendPQExpBuffer(querybuf, " WITH %s", optbuf->data);
				if (dump_this_grantor)
					appendPQExpBuffer(querybuf, " GRANTED BY %s", fmtId(grantor));
				appendPQExpBufferStr(querybuf, ";\n");

				ArchiveEntry(fout,
							 nilCatalogId,	/* catalog ID */
							 createDumpId(),	/* dump ID */
							 ARCHIVE_OPTS(.tag = psprintf("ROLE %s", fmtId(role)),
										  .description = "ROLE PROPERTIES",
										  .section = SECTION_PRE_DATA,
										  .createStmt = querybuf->data));
			}
		}

		rolename_destroy(ht);
		pg_free(done);
		start = end;
	}

	PQclear(res);
	destroyPQExpBuffer(buf);
	destroyPQExpBuffer(querybuf);
	destroyPQExpBuffer(optbuf);
}


/*
 * Dump role configuration parameter privileges.  This code is used for 15.0
 * and later servers.
 *
 * Note: we expect dumpRoles already created all the roles, but there are
 * no per-role configuration parameter privileges yet.
 */
static void
dumpRoleGUCPrivs(PGconn *conn)
{
	PGresult   *res;
	int			i;

	/*
	 * Get all parameters that have non-default acls defined.
	 */
	res = executeQuery(conn, "SELECT parname, "
					   "pg_catalog.pg_get_userbyid(" CppAsString2(BOOTSTRAP_SUPERUSERID) ") AS parowner, "
					   "paracl, "
					   "pg_catalog.acldefault('p', " CppAsString2(BOOTSTRAP_SUPERUSERID) ") AS acldefault "
					   "FROM pg_catalog.pg_parameter_acl "
					   "ORDER BY 1");

	for (i = 0; i < PQntuples(res); i++)
	{
		PQExpBuffer buf = createPQExpBuffer();
		char	   *parname = PQgetvalue(res, i, 0);
		char	   *parowner = PQgetvalue(res, i, 1);
		char	   *paracl = PQgetvalue(res, i, 2);
		char	   *acldefault = PQgetvalue(res, i, 3);
		char	   *fparname;

		/* needed for buildACLCommands() */
		fparname = pg_strdup(fmtId(parname));

		if (!buildACLCommands(fparname, NULL, NULL, "PARAMETER",
							  paracl, acldefault,
							  parowner, "", server_version, buf))
		{
			pg_log_error("could not parse ACL list (%s) for parameter \"%s\"",
						 paracl, parname);
			PQfinish(conn);
			exit_nicely(1);
		}

		ArchiveEntry(fout,
					 nilCatalogId,	/* catalog ID */
					 createDumpId(),	/* dump ID */
					 ARCHIVE_OPTS(.tag = psprintf("ROLE %s", fmtId(parowner)),
								  .description = "ROLE PROPERTIES",
								  .section = SECTION_PRE_DATA,
								  .createStmt = buf->data));

		pg_free(fparname);
		destroyPQExpBuffer(buf);
	}

	PQclear(res);
}


/*
 * Drop and dump tablespaces.
 */
static void
dumpTablespaces(PGconn *conn)
{
	PGresult   *res;
	PQExpBuffer delQry = createPQExpBuffer();
	PQExpBuffer comment_buf = createPQExpBuffer();
	PQExpBuffer seclabel_buf = createPQExpBuffer();
	int			i;

	/*
	 * Get all tablespaces except built-in ones (which we assume are named
	 * pg_xxx)
	 */
	res = executeQuery(conn, "SELECT oid, spcname, "
					   "pg_catalog.pg_get_userbyid(spcowner) AS spcowner, "
					   "pg_catalog.pg_tablespace_location(oid), "
					   "spcacl, acldefault('t', spcowner) AS acldefault, "
					   "array_to_string(spcoptions, ', '),"
					   "pg_catalog.shobj_description(oid, 'pg_tablespace') "
					   "FROM pg_catalog.pg_tablespace "
					   "WHERE spcname !~ '^pg_' "
					   "ORDER BY 1");

	for (i = 0; i < PQntuples(res); i++)
	{
		PQExpBuffer buf = createPQExpBuffer();
		Oid			spcoid = atooid(PQgetvalue(res, i, 0));
		char	   *spcname = PQgetvalue(res, i, 1);
		char	   *spcowner = PQgetvalue(res, i, 2);
		char	   *spclocation = PQgetvalue(res, i, 3);
		char	   *spcacl = PQgetvalue(res, i, 4);
		char	   *acldefault = PQgetvalue(res, i, 5);
		char	   *spcoptions = PQgetvalue(res, i, 6);
		char	   *spccomment = PQgetvalue(res, i, 7);
		char	   *fspcname;
		char	   *tag;
		DumpId		spcDumpId;

		/* needed for buildACLCommands() */
		fspcname = pg_strdup(fmtId(spcname));

		resetPQExpBuffer(delQry);
		resetPQExpBuffer(comment_buf);
		resetPQExpBuffer(seclabel_buf);

		appendPQExpBuffer(delQry, "DROP TABLESPACE %s;\n", fspcname);

		if (binary_upgrade)
		{
			appendPQExpBufferStr(buf, "\n-- For binary upgrade, must preserve pg_tablespace oid\n");
			appendPQExpBuffer(buf, "SELECT pg_catalog.binary_upgrade_set_next_pg_tablespace_oid('%u'::pg_catalog.oid);\n", spcoid);
		}

		appendPQExpBuffer(buf, "CREATE TABLESPACE %s", fspcname);
		appendPQExpBuffer(buf, " OWNER %s", fmtId(spcowner));

		appendPQExpBufferStr(buf, " LOCATION ");

		/*
		 * In-place tablespaces use a relative path, and need to be dumped
		 * with an empty string as location.
		 */
		if (is_absolute_path(spclocation))
			appendStringLiteralConn(buf, spclocation, conn);
		else
			appendStringLiteralConn(buf, "", conn);

		appendPQExpBufferStr(buf, ";\n");

		if (spcoptions && spcoptions[0] != '\0')
			appendPQExpBuffer(buf, "ALTER TABLESPACE %s SET (%s);\n",
							  fspcname, spcoptions);

		/* tablespaces can't have initprivs */

		if (!skip_acls &&
			!buildACLCommands(fspcname, NULL, NULL, "TABLESPACE",
							  spcacl, acldefault,
							  spcowner, "", server_version, buf))
		{
			pg_log_error("could not parse ACL list (%s) for tablespace \"%s\"",
						 spcacl, spcname);
			PQfinish(conn);
			exit_nicely(1);
		}

		if (!no_comments && spccomment && spccomment[0] != '\0')
		{
			appendPQExpBuffer(comment_buf, "COMMENT ON TABLESPACE %s IS ", fspcname);
			appendStringLiteralConn(comment_buf, spccomment, conn);
			appendPQExpBufferStr(comment_buf, ";\n");
		}

		if (!no_security_labels)
			buildShSecLabels(conn, "pg_tablespace", spcoid,
							 "TABLESPACE", spcname,
							 seclabel_buf);

		tag = psprintf("TABLESPACE %s", fspcname);
		spcDumpId = createDumpId();

		ArchiveEntry(fout,
					 nilCatalogId,	/* catalog ID */
					 spcDumpId, /* dump ID */
					 ARCHIVE_OPTS(.tag = tag,
								  .description = "TABLESPACE",
								  .section = SECTION_PRE_DATA,
								  .createStmt = buf->data,
								  .dropStmt = delQry->data));

		if (comment_buf->data[0] != '\0')
			ArchiveEntry(fout,
						 nilCatalogId,	/* catalog ID */
						 createDumpId(),	/* dump ID */
						 ARCHIVE_OPTS(.tag = tag,
									  .description = "COMMENT",
									  .section = SECTION_PRE_DATA,
									  .createStmt = comment_buf->data,
									  .deps = &spcDumpId,
									  .nDeps = 1));

		if (seclabel_buf->data[0] != '\0')
			ArchiveEntry(fout,
						 nilCatalogId,	/* catalog ID */
						 createDumpId(),	/* dump ID */
						 ARCHIVE_OPTS(.tag = tag,
									  .description = "SECURITY LABEL",
									  .section = SECTION_PRE_DATA,
									  .createStmt = seclabel_buf->data,
									  .deps = &spcDumpId,
									  .nDeps = 1));

		free(tag);

		pg_free(fspcname);
		destroyPQExpBuffer(buf);
	}

	PQclear(res);
	destroyPQExpBuffer(delQry);
	destroyPQExpBuffer(comment_buf);
	destroyPQExpBuffer(seclabel_buf);
}


/*
 * Dump user-specific configuration
 */
static void
dumpUserConfig(PGconn *conn, const char *username)
{
	PQExpBuffer buf = createPQExpBuffer();
	PGresult   *res;

	printfPQExpBuffer(buf, "SELECT unnest(setconfig) FROM pg_db_role_setting "
					  "WHERE setdatabase = 0 AND setrole = "
					  "(SELECT oid FROM %s WHERE rolname = ",
					  role_catalog);
	appendStringLiteralConn(buf, username, conn);
	appendPQExpBufferChar(buf, ')');

	res = executeQuery(conn, buf->data);

	for (int i = 0; i < PQntuples(res); i++)
	{
		resetPQExpBuffer(buf);
		makeAlterConfigCommand(conn, PQgetvalue(res, i, 0),
							   "ROLE", username, NULL, NULL,
							   buf);

		ArchiveEntry(fout,
					 nilCatalogId,	/* catalog ID */
					 createDumpId(),	/* dump ID */
					 ARCHIVE_OPTS(.tag = psprintf("ROLE %s", fmtId(username)),
								  .description = "ROLE PROPERTIES",
								  .section = SECTION_PRE_DATA,
								  .createStmt = buf->data));
	}

	PQclear(res);

	destroyPQExpBuffer(buf);
}

/*
 * Find a list of database names that match the given patterns.
 * See also expand_table_name_patterns() in pg_dump.c
 */
static void
expand_dbname_patterns(PGconn *conn,
					   SimpleStringList *patterns,
					   SimpleStringList *names)
{
	PQExpBuffer query;
	PGresult   *res;

	if (patterns->head == NULL)
		return;					/* nothing to do */

	query = createPQExpBuffer();

	/*
	 * The loop below runs multiple SELECTs, which might sometimes result in
	 * duplicate entries in the name list, but we don't care, since all we're
	 * going to do is test membership of the list.
	 */

	for (SimpleStringListCell *cell = patterns->head; cell; cell = cell->next)
	{
		int			dotcnt;

		appendPQExpBufferStr(query,
							 "SELECT datname FROM pg_catalog.pg_database n\n");
		processSQLNamePattern(conn, query, cell->val, false,
							  false, NULL, "datname", NULL, NULL, NULL,
							  &dotcnt);

		if (dotcnt > 0)
		{
			pg_log_error("improper qualified name (too many dotted names): %s",
						 cell->val);
			PQfinish(conn);
			exit_nicely(1);
		}

		res = executeQuery(conn, query->data);
		for (int i = 0; i < PQntuples(res); i++)
		{
			simple_string_list_append(names, PQgetvalue(res, i, 0));
		}

		PQclear(res);
		resetPQExpBuffer(query);
	}

	destroyPQExpBuffer(query);
}

/*
 * Register a drop-only archive entry for each database that dumpDatabases()
 * will recreate.  A database may depend on a tablespace or role, so it must
 * be dropped before them.  The archiver's drop pass processes entries in
 * reverse registration order, so this must be called after dumpRoles() and
 * dumpTablespaces().
 *
 * template1 and postgres are skipped: they are assumed to exist in the target
 * cluster, and with --clean dumpDatabases() has pg_dump drop and recreate
 * them instead.  IF EXISTS, if requested, is added by the archiver.
 */
static void
dropDatabases(PGconn *conn)
{
	PQExpBuffer delQry = createPQExpBuffer();
	PGresult   *res;

	/* This must agree with dumpDatabases() */
	res = executeQuery(conn,
					   "SELECT oid, datname "
					   "FROM pg_catalog.pg_database "
					   "WHERE datallowconn AND datconnlimit != -2 "
					   "AND datname NOT IN ('template0', 'template1', 'postgres') "
					   "ORDER BY datname");

	for (int i = 0; i < PQntuples(res); i++)
	{
		CatalogId	dbCatId;
		char	   *dbname = PQgetvalue(res, i, 1);

		/* Excluded databases are not recreated, so don't drop them either */
		if (simple_string_list_member(&database_exclude_names, dbname))
			continue;

		/*
		 * Record the database's OID, which is what map.dat uses, so that
		 * pg_restore can tell which database each drop belongs to.
		 */
		dbCatId.tableoid = InvalidOid;
		dbCatId.oid = atooid(PQgetvalue(res, i, 0));

		resetPQExpBuffer(delQry);
		appendPQExpBuffer(delQry, "DROP DATABASE %s;\n", fmtId(dbname));

		ArchiveEntry(fout,
					 dbCatId,	/* catalog ID */
					 createDumpId(),	/* dump ID */
					 ARCHIVE_OPTS(.tag = psprintf("DATABASE %s", fmtId(dbname)),
								  .description = "DROP_GLOBAL",
								  .section = SECTION_PRE_DATA,
								  .dropStmt = delQry->data));
	}

	PQclear(res);
	destroyPQExpBuffer(delQry);
}

/*
 * Dump contents of databases.
 */
static void
dumpDatabases(PGconn *conn)
{
	PGresult   *res;
	int			i;
	char		db_subdir[MAXPGPATH];
	char		dbfilepath[MAXPGPATH];
	FILE	   *map_file = NULL;

	/*
	 * Skip databases marked not datallowconn, since we'd be unable to connect
	 * to them anyway.
	 *
	 * We arrange for template1 to be processed first, then we process other
	 * DBs in alphabetical order.  If we just did them all alphabetically, we
	 * might find ourselves trying to drop the "postgres" database while still
	 * connected to it.  This makes trying to run the restore script while
	 * connected to "template1" a bad idea, but there's no fixed order that
	 * doesn't have some failure mode with --clean.
	 */
	res = executeQuery(conn,
					   "SELECT datname, oid "
					   "FROM pg_database d "
					   "WHERE datallowconn AND datconnlimit != -2 "
					   "ORDER BY (datname <> 'template1'), datname");

	if (PQntuples(res) > 0 && archDumpFormat == archNull)
		fprintf(OPF, "--\n-- Databases\n--\n\n");

	/*
	 * If directory/tar/custom format is specified, create a subdirectory
	 * under the main directory and each database dump file or subdirectory
	 * will be created in that subdirectory by pg_dump.
	 */
	if (archDumpFormat != archNull)
	{
		char		map_file_path[MAXPGPATH];

		snprintf(db_subdir, MAXPGPATH, "%s/databases", filename);

		/* Create a subdirectory with 'databases' name under main directory. */
		if (mkdir(db_subdir, pg_dir_create_mode) != 0)
			pg_fatal("could not create directory \"%s\": %m", db_subdir);

		snprintf(map_file_path, MAXPGPATH, "%s/map.dat", filename);

		/* Create a map file (to store dboid and dbname) */
		map_file = fopen(map_file_path, PG_BINARY_W);
		if (!map_file)
			pg_fatal("could not open file \"%s\": %m", map_file_path);

		fprintf(map_file,
				"#################################################################\n"
				"# map.dat\n"
				"#\n"
				"# This file maps oids to database names\n"
				"#\n"
				"# pg_restore will restore all the databases listed here, unless\n"
				"# otherwise excluded. You can also inhibit restoration of a\n"
				"# database by removing the line or commenting out the line with\n"
				"# a # mark.\n"
				"#################################################################\n");
	}

	for (i = 0; i < PQntuples(res); i++)
	{
		char	   *dbname = PQgetvalue(res, i, 0);
		char	   *sanitized;
		char	   *oid = PQgetvalue(res, i, 1);
		const char *create_opts = "";
		int			ret;

		/* Skip template0, even if it's not marked !datallowconn. */
		if (strcmp(dbname, "template0") == 0)
			continue;

		/* Skip any explicitly excluded database */
		if (simple_string_list_member(&database_exclude_names, dbname))
		{
			pg_log_info("excluding database \"%s\"", dbname);
			continue;
		}

		pg_log_info("dumping database \"%s\"", dbname);

		sanitized = sanitize_line(dbname, true);

		if (archDumpFormat == archNull)
			fprintf(OPF, "--\n-- Database \"%s\" dump\n--\n\n", sanitized);

		free(sanitized);

		/*
		 * We assume that "template1" and "postgres" already exist in the
		 * target installation and are never dropped by dropDatabases(), for
		 * fear of dropping the DB the restore script is initially connected
		 * to.  If --clean was specified, tell pg_dump to drop and recreate
		 * them; otherwise we'll merely restore their contents.  Other
		 * databases should simply be created.
		 */
		if (strcmp(dbname, "template1") == 0 || strcmp(dbname, "postgres") == 0)
		{
			if (output_clean)
				create_opts = "--clean --create";
			/* Since pg_dump won't emit a \connect command, we must */
			else if (archDumpFormat == archNull)
				fprintf(OPF, "\\connect %s\n\n", dbname);
			else
				create_opts = "";
		}
		else
			create_opts = "--create";

		if (archDumpFormat != archNull)
		{
			/* Compute this database's own archive file path. */
			if (archDumpFormat == archCustom)
				snprintf(dbfilepath, MAXPGPATH, "%s/%s.dmp", db_subdir, oid);
			else if (archDumpFormat == archTar)
				snprintf(dbfilepath, MAXPGPATH, "%s/%s.tar", db_subdir, oid);
			else
				snprintf(dbfilepath, MAXPGPATH, "%s/%s", db_subdir, oid);

			/* Put one line entry for dboid and dbname in map file. */
			fprintf(map_file, "%s %s\n", oid, dbname);
		}

		ret = runPgDump(dbname, create_opts, dbfilepath);
		if (ret != 0)
			pg_fatal("pg_dump failed on database \"%s\", exiting", dbname);
	}

	/* Close map file */
	if (archDumpFormat != archNull)
	{
		char		map_file_path[MAXPGPATH];

		fclose(map_file);

		if (dosync)
		{
			snprintf(map_file_path, MAXPGPATH, "%s/map.dat", filename);
			(void) fsync_fname(map_file_path, false);
		}
	}

	PQclear(res);
}



/*
 * Run pg_dump on dbname, with specified options.
 */
static int
runPgDump(const char *dbname, const char *create_opts, char *dbfile)
{
	PQExpBufferData connstrbuf;
	PQExpBufferData cmd;
	int			ret;

	initPQExpBuffer(&connstrbuf);
	initPQExpBuffer(&cmd);

	/*
	 * If this is not a plain format dump, append the file name and dump
	 * format to the pg_dump command to produce an archive-format dump.
	 */
	if (archDumpFormat != archNull)
	{
		printfPQExpBuffer(&cmd, "\"%s\" %s -f ", pg_dump_bin, pgdumpopts->data);
		appendShellString(&cmd, dbfile);
		appendPQExpBuffer(&cmd, " %s", create_opts);

		if (archDumpFormat == archDirectory)
			appendPQExpBufferStr(&cmd, " --format=directory ");
		else if (archDumpFormat == archCustom)
			appendPQExpBufferStr(&cmd, " --format=custom ");
		else if (archDumpFormat == archTar)
			appendPQExpBufferStr(&cmd, " --format=tar ");
	}
	else
	{
		printfPQExpBuffer(&cmd, "\"%s\" %s %s", pg_dump_bin,
						  pgdumpopts->data, create_opts);

		/*
		 * If we have a filename, use the undocumented plain-append pg_dump
		 * format.
		 */
		if (filename)
		{
			appendPQExpBufferStr(&cmd, " -Fa -f ");
			appendShellString(&cmd, filename);
			appendPQExpBufferChar(&cmd, ' ');
		}
		else
			appendPQExpBufferStr(&cmd, " -Fp ");
	}

	/*
	 * Append the database name to the already-constructed stem of connection
	 * string.
	 */
	appendPQExpBuffer(&connstrbuf, "%s dbname=", connstr);
	appendConnStrVal(&connstrbuf, dbname);

	appendShellString(&cmd, connstrbuf.data);

	pg_log_info("running \"%s\"", cmd.data);

	fflush(NULL);

	ret = system(cmd.data);

	termPQExpBuffer(&cmd);
	termPQExpBuffer(&connstrbuf);

	return ret;
}

/*
 * buildShSecLabels
 *
 * Build SECURITY LABEL command(s) for a shared object
 *
 * The caller has to provide object type and identity in two separate formats:
 * catalog_name (e.g., "pg_database") and object OID, as well as
 * type name (e.g., "DATABASE") and object name (not pre-quoted).
 *
 * The command(s) are appended to "buffer".
 */
static void
buildShSecLabels(PGconn *conn, const char *catalog_name, Oid objectId,
				 const char *objtype, const char *objname,
				 PQExpBuffer buffer)
{
	PQExpBuffer sql = createPQExpBuffer();
	PGresult   *res;

	buildShSecLabelQuery(catalog_name, objectId, sql);
	res = executeQuery(conn, sql->data);
	emitShSecLabels(conn, res, buffer, objtype, objname);

	PQclear(res);
	destroyPQExpBuffer(sql);
}

/*
 * As above for a SQL command (which returns nothing).
 */
static void
executeCommand(PGconn *conn, const char *query)
{
	PGresult   *res;

	pg_log_info("executing %s", query);

	res = PQexec(conn, query);
	if (!res ||
		PQresultStatus(res) != PGRES_COMMAND_OK)
	{
		pg_log_error("query failed: %s", PQerrorMessage(conn));
		pg_log_error_detail("Query was: %s", query);
		PQfinish(conn);
		exit_nicely(1);
	}

	PQclear(res);
}


/*
 * check_for_invalid_global_names
 *
 * Check that no database, role, or tablespace name contains a newline or
 * carriage return character, and if any does, report all of them and exit.
 * Such characters in database names would break the line-oriented map.dat
 * file used for non-plain-text dumps.  Role and tablespace names are checked
 * too, because servers starting with v19 reject such names, so restoring
 * them would fail anyway; it's friendlier to say so now.
 *
 * Excluded databases are skipped since they won't appear in map.dat.
 */
static void
check_for_invalid_global_names(PGconn *conn,
							   SimpleStringList *excluded_names)
{
	PQExpBuffer query = createPQExpBuffer();
	PQExpBuffer names;
	PGresult   *res;

	appendPQExpBufferStr(query,
						 "SELECT datname AS objname, 'database' AS objtype "
						 "FROM pg_catalog.pg_database "
						 "WHERE datallowconn AND datconnlimit != -2 "
						 "AND datname ~ E'[\\n\\r]'");

	for (SimpleStringListCell *cell = excluded_names->head; cell; cell = cell->next)
	{
		appendPQExpBufferStr(query, " AND datname <> ");
		appendStringLiteralConn(query, cell->val, conn);
	}

	appendPQExpBufferStr(query,
						 " UNION ALL "
						 "SELECT rolname, 'role' "
						 "FROM pg_catalog.pg_roles "
						 "WHERE rolname ~ E'[\\n\\r]' "
						 "UNION ALL "
						 "SELECT spcname, 'tablespace' "
						 "FROM pg_catalog.pg_tablespace "
						 "WHERE spcname ~ E'[\\n\\r]' "
						 "ORDER BY 2, 1");

	res = executeQuery(conn, query->data);
	destroyPQExpBuffer(query);

	if (PQntuples(res) == 0)
	{
		PQclear(res);
		return;
	}

	/*
	 * List the offending names, showing newline and carriage return as \n and
	 * \r
	 */
	names = createPQExpBuffer();
	for (int i = 0; i < PQntuples(res); i++)
	{
		appendPQExpBuffer(names, "  %s: \"", PQgetvalue(res, i, 1));
		for (char *p = PQgetvalue(res, i, 0); *p; p++)
		{
			if (*p == '\n')
				appendPQExpBufferStr(names, "\\n");
			else if (*p == '\r')
				appendPQExpBufferStr(names, "\\r");
			else
				appendPQExpBufferChar(names, *p);
		}
		appendPQExpBufferStr(names, "\"\n");
	}

	pg_fatal("database, role, or tablespace names contain a newline or carriage return character, which is not supported in non-plain-text dumps:\n%s",
			 names->data);
}


/*
 * dumpTimestamp
 */
static void
dumpTimestamp(const char *msg)
{
	char		buf[64];
	time_t		now = time(NULL);

	if (strftime(buf, sizeof(buf), PGDUMP_STRFTIME_FMT, localtime(&now)) != 0)
		fprintf(OPF, "-- %s %s\n\n", msg, buf);
}

/*
 * read_dumpall_filters - retrieve database identifier patterns from file
 *
 * Parse the specified filter file for include and exclude patterns, and add
 * them to the relevant lists.  If the filename is "-" then filters will be
 * read from STDIN rather than a file.
 *
 * At the moment, the only allowed filter is for database exclusion.
 */
static void
read_dumpall_filters(const char *filename, SimpleStringList *pattern)
{
	FilterStateData fstate;
	char	   *objname;
	FilterCommandType comtype;
	FilterObjectType objtype;

	filter_init(&fstate, filename, exit);

	while (filter_read_item(&fstate, &objname, &comtype, &objtype))
	{
		if (comtype == FILTER_COMMAND_TYPE_INCLUDE)
		{
			pg_log_filter_error(&fstate, _("%s filter for \"%s\" is not allowed"),
								"include",
								filter_object_type_name(objtype));
			exit_nicely(1);
		}

		switch (objtype)
		{
			case FILTER_OBJECT_TYPE_NONE:
				break;
			case FILTER_OBJECT_TYPE_FUNCTION:
			case FILTER_OBJECT_TYPE_INDEX:
			case FILTER_OBJECT_TYPE_TABLE_DATA:
			case FILTER_OBJECT_TYPE_TABLE_DATA_AND_CHILDREN:
			case FILTER_OBJECT_TYPE_TRIGGER:
			case FILTER_OBJECT_TYPE_EXTENSION:
			case FILTER_OBJECT_TYPE_FOREIGN_DATA:
			case FILTER_OBJECT_TYPE_SCHEMA:
			case FILTER_OBJECT_TYPE_TABLE:
			case FILTER_OBJECT_TYPE_TABLE_AND_CHILDREN:
				pg_log_filter_error(&fstate, _("unsupported filter object"));
				exit_nicely(1);
				break;

			case FILTER_OBJECT_TYPE_DATABASE:
				simple_string_list_append(pattern, objname);
				break;
		}

		if (objname)
			free(objname);
	}

	filter_free(&fstate);
}

/*
 * parseDumpFormat
 *
 * This will validate dump formats.
 */
static ArchiveFormat
parseDumpFormat(const char *format)
{
	if (pg_strcasecmp(format, "c") == 0)
		return archCustom;
	else if (pg_strcasecmp(format, "custom") == 0)
		return archCustom;
	else if (pg_strcasecmp(format, "d") == 0)
		return archDirectory;
	else if (pg_strcasecmp(format, "directory") == 0)
		return archDirectory;
	else if (pg_strcasecmp(format, "p") == 0)
		return archNull;
	else if (pg_strcasecmp(format, "plain") == 0)
		return archNull;
	else if (pg_strcasecmp(format, "t") == 0)
		return archTar;
	else if (pg_strcasecmp(format, "tar") == 0)
		return archTar;
	else
		pg_fatal("unrecognized output format \"%s\"; please specify \"c\", \"d\", \"p\", or \"t\"",
				 format);

	return archUnknown;
}

/*
 * createDumpId
 *
 * Return the next dumpId.
 *
 * This is a local, file-scope copy of pg_dump.c's createDumpId() rather
 * than a shared one: that function's home, common.c, is compiled only
 * into the pg_dump binary (pg_dump_sources in meson.build), not into
 * pg_dump_common, the static library pg_dumpall and pg_restore link
 * against, so it isn't available here to call.
 */
static DumpId
createDumpId(void)
{
	return ++lastDumpId;
}

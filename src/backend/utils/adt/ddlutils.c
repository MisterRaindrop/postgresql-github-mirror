/*-------------------------------------------------------------------------
 *
 * ddlutils.c
 *		Utility functions for generating DDL statements
 *
 * This file contains the pg_get_*_ddl family of functions that generate
 * DDL statements to recreate database objects such as roles, tablespaces,
 * and databases, along with common infrastructure for option parsing and
 * pretty-printing.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  src/backend/utils/adt/ddlutils.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "catalog/dependency.h"
#include "catalog/pg_auth_members.h"
#include "catalog/pg_authid.h"
#include "catalog/pg_collation.h"
#include "catalog/pg_database.h"
#include "catalog/pg_db_role_setting.h"
#include "catalog/pg_tablespace.h"
#include "commands/tablespace.h"
#include "common/relpath.h"
#include "funcapi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/pg_locale.h"
#include "utils/rel.h"
#include "utils/syscache.h"
#include "utils/timestamp.h"
#include "utils/varlena.h"

static void append_ddl_option(StringInfo buf, bool pretty, int indent,
							  const char *fmt, ...)
			pg_attribute_printf(4, 5);
static void append_guc_value(StringInfo buf, const char *name,
							 const char *value);
static void push_statement(List **statements, StringInfo buf);
static Datum ddl_statements_srf(FunctionCallInfo fcinfo,
								List *(*getstatements) (void *arg),
								void *arg);
static List *get_role_ddl_statements(void *arg);
static List *get_tablespace_ddl_statements(void *arg);
static List *get_database_ddl_statements(void *arg);
static List *pg_get_role_ddl_internal(Oid roleid, bool pretty,
									  bool memberships, bool password,
									  bool in_database_settings);
static List *pg_get_tablespace_ddl_internal(Oid tsid, bool pretty, bool no_owner);
static Datum pg_get_tablespace_ddl_srf(FunctionCallInfo fcinfo, Oid tsid);
static List *pg_get_database_ddl_internal(Oid dbid, bool pretty,
										  bool no_owner, bool no_tablespace);


/*
 * Helper to append a formatted string with optional pretty-printing.
 */
static void
append_ddl_option(StringInfo buf, bool pretty, int indent,
				  const char *fmt, ...)
{
	if (pretty)
	{
		appendStringInfoChar(buf, '\n');
		appendStringInfoSpaces(buf, indent);
	}
	else
		appendStringInfoChar(buf, ' ');

	for (;;)
	{
		va_list		args;
		int			needed;

		va_start(args, fmt);
		needed = appendStringInfoVA(buf, fmt, args);
		va_end(args);
		if (needed == 0)
			break;
		enlargeStringInfo(buf, needed);
	}
}

/*
 * append_guc_value
 *		Append a GUC setting value to buf, handling GUC_LIST_QUOTE properly.
 *
 * Variables marked GUC_LIST_QUOTE were already fully quoted before they
 * were stored in the setconfig array.  We break the list value apart
 * and re-quote the elements as string literals.  For all other variables
 * we simply quote the value as a single string literal.
 *
 * The caller has already appended "SET <name> TO " to buf.
 */
static void
append_guc_value(StringInfo buf, const char *name, const char *value)
{
	char	   *rawval;

	rawval = pstrdup(value);

	if (GetConfigOptionFlags(name, true) & GUC_LIST_QUOTE)
	{
		List	   *namelist;
		bool		first = true;

		/* Parse string into list of identifiers */
		if (!SplitGUCList(rawval, ',', &namelist))
		{
			/* this shouldn't fail really */
			elog(ERROR, "invalid list syntax in setconfig item");
		}
		/* Special case: represent an empty list as NULL */
		if (namelist == NIL)
			appendStringInfoString(buf, "NULL");
		foreach_ptr(char, curname, namelist)
		{
			if (first)
				first = false;
			else
				appendStringInfoString(buf, ", ");
			appendStringInfoString(buf, quote_literal_cstr(curname));
		}
		list_free(namelist);
	}
	else
		appendStringInfoString(buf, quote_literal_cstr(rawval));

	pfree(rawval);
}

/*
 * push_statement
 *		Append the SQL text currently in buf to *statements as a
 *		separate, complete statement, then reset buf so the caller can
 *		build the next one.
 */
static void
push_statement(List **statements, StringInfo buf)
{
	*statements = lappend(*statements, pstrdup(buf->data));
	resetStringInfo(buf);
}

/*
 * pg_get_role_ddl_internal
 *		Generate DDL statements to recreate a role
 *
 * Returns a List of palloc'd strings, each being a complete SQL statement.
 * The first two elements are the CREATE ROLE statement and an ALTER ROLE
 * carrying the attributes; the rest are ALTER ROLE SET statements, plus
 * GRANT statements for memberships if requested.
 */
static List *
pg_get_role_ddl_internal(Oid roleid, bool pretty, bool memberships,
						 bool password, bool in_database_settings)
{
	HeapTuple	tuple;
	Form_pg_authid roleform;
	StringInfoData buf;
	char	   *rolname;
	Datum		rolpassword;
	Datum		rolevaliduntil;
	bool		isnull;
	Relation	rel;
	ScanKeyData scankey;
	SysScanDesc scan;
	List	   *statements = NIL;

	tuple = SearchSysCache1(AUTHOID, ObjectIdGetDatum(roleid));
	if (!HeapTupleIsValid(tuple))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("role with OID %u does not exist", roleid)));

	roleform = (Form_pg_authid) GETSTRUCT(tuple);
	rolname = pstrdup(NameStr(roleform->rolname));

	/*
	 * rolpassword needs SELECT on pg_authid; nothing else here is
	 * sensitive, so only check it when the PASSWORD clause is wanted.
	 */
	if (password &&
		pg_class_aclcheck(AuthIdRelationId, GetUserId(),
						  ACL_SELECT) != ACLCHECK_OK)
	{
		ReleaseSysCache(tuple);
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied for role %s", rolname)));
	}

	/*
	 * Lock and re-verify existence, closing the window for a concurrent
	 * DROP ROLE before the scans below.
	 */
	shdepLockAndCheckObject(AuthIdRelationId, roleid);

	/*
	 * We don't support generating DDL for system roles.  The primary reason
	 * for this is that users shouldn't be recreating them.
	 */
	if (IsReservedName(rolname))
		ereport(ERROR,
				(errcode(ERRCODE_RESERVED_NAME),
				 errmsg("role name \"%s\" is reserved", rolname),
				 errdetail("Role names starting with \"pg_\" are reserved for system roles.")));

	initStringInfo(&buf);

	/*
	 * Attributes go in a separate ALTER ROLE, as pg_dumpall does, so they
	 * still apply when replayed over a role that already exists.
	 */
	appendStringInfo(&buf, "CREATE ROLE %s;", quote_identifier(rolname));
	push_statement(&statements, &buf);

	appendStringInfo(&buf, "ALTER ROLE %s WITH", quote_identifier(rolname));

	/*
	 * Append role attributes.  The order here follows the same sequence as
	 * you'd typically write them in an ALTER ROLE command, though any order
	 * is actually acceptable to the parser.
	 */
	append_ddl_option(&buf, pretty, 4, "%s",
					  roleform->rolsuper ? "SUPERUSER" : "NOSUPERUSER");

	append_ddl_option(&buf, pretty, 4, "%s",
					  roleform->rolinherit ? "INHERIT" : "NOINHERIT");

	append_ddl_option(&buf, pretty, 4, "%s",
					  roleform->rolcreaterole ? "CREATEROLE" : "NOCREATEROLE");

	append_ddl_option(&buf, pretty, 4, "%s",
					  roleform->rolcreatedb ? "CREATEDB" : "NOCREATEDB");

	append_ddl_option(&buf, pretty, 4, "%s",
					  roleform->rolcanlogin ? "LOGIN" : "NOLOGIN");

	append_ddl_option(&buf, pretty, 4, "%s",
					  roleform->rolreplication ? "REPLICATION" : "NOREPLICATION");

	append_ddl_option(&buf, pretty, 4, "%s",
					  roleform->rolbypassrls ? "BYPASSRLS" : "NOBYPASSRLS");

	/*
	 * CONNECTION LIMIT is only interesting if it's not -1 (the default,
	 * meaning no limit).
	 */
	if (roleform->rolconnlimit >= 0)
		append_ddl_option(&buf, pretty, 4, "CONNECTION LIMIT %d",
						  roleform->rolconnlimit);

	/* PASSWORD is the stored verifier; the plaintext isn't recoverable. */
	rolpassword = SysCacheGetAttr(AUTHOID, tuple,
								  Anum_pg_authid_rolpassword,
								  &isnull);
	if (password && !isnull)
	{
		char	   *verifier = TextDatumGetCString(rolpassword);

		append_ddl_option(&buf, pretty, 4, "PASSWORD %s",
						  quote_literal_cstr(verifier));
		pfree(verifier);
	}

	rolevaliduntil = SysCacheGetAttr(AUTHOID, tuple,
									 Anum_pg_authid_rolvaliduntil,
									 &isnull);
	if (!isnull)
	{
		/*
		 * timestamptz_to_str() already formats in ISO style regardless of the
		 * session's DateStyle, which is what we want here: the output must
		 * parse the same in any receiving session.  timestamptz_out() is not
		 * a substitute -- it honors DateStyle.
		 */
		append_ddl_option(&buf, pretty, 4, "VALID UNTIL %s",
						  quote_literal_cstr(timestamptz_to_str(DatumGetTimestampTz(rolevaliduntil))));
	}

	ReleaseSysCache(tuple);

	appendStringInfoChar(&buf, ';');

	push_statement(&statements, &buf);

	/*
	 * Now scan pg_db_role_setting for ALTER ROLE SET configurations.
	 *
	 * These can be role-wide (setdatabase = 0) or specific to a particular
	 * database (setdatabase = a valid DB OID).  It generates one ALTER
	 * statement per setting.
	 */
	rel = table_open(DbRoleSettingRelationId, AccessShareLock);
	ScanKeyInit(&scankey,
				Anum_pg_db_role_setting_setrole,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(roleid));
	scan = systable_beginscan(rel, DbRoleSettingDatidRolidIndexId, true,
							  NULL, 1, &scankey);

	while (HeapTupleIsValid(tuple = systable_getnext(scan)))
	{
		Form_pg_db_role_setting setting = (Form_pg_db_role_setting) GETSTRUCT(tuple);
		Oid			datid = setting->setdatabase;
		Datum		datum;
		ArrayType  *role_settings;
		Datum	   *settings;
		bool	   *nulls;
		int			nsettings;
		char	   *datname = NULL;

		/*
		 * If setdatabase is valid, this is a role-in-database setting;
		 * otherwise it's a role-wide setting.  In-database settings depend on
		 * that database already existing, so they're optional; role-wide ones
		 * are not.  Look up the database name once for all settings in this
		 * row.
		 */
		if (OidIsValid(datid))
		{
			if (!in_database_settings)
				continue;

			datname = get_database_name(datid);
			/* Database has been dropped; skip all settings in this row. */
			if (datname == NULL)
				continue;
		}

		/*
		 * The setconfig column is a text array in "name=value" format. It
		 * should never be null for a valid row, but be defensive.
		 */
		datum = heap_getattr(tuple, Anum_pg_db_role_setting_setconfig,
							 RelationGetDescr(rel), &isnull);
		if (isnull)
			continue;

		role_settings = DatumGetArrayTypePCopy(datum);

		deconstruct_array_builtin(role_settings, TEXTOID, &settings, &nulls, &nsettings);

		for (int i = 0; i < nsettings; i++)
		{
			char	   *s,
					   *p;

			if (nulls[i])
				continue;

			s = TextDatumGetCString(settings[i]);
			p = strchr(s, '=');
			if (p == NULL)
			{
				pfree(s);
				continue;
			}
			*p++ = '\0';

			/* Build a fresh ALTER ROLE statement for this setting */
			appendStringInfo(&buf, "ALTER ROLE %s", quote_identifier(rolname));

			if (datname != NULL)
				appendStringInfo(&buf, " IN DATABASE %s",
								 quote_identifier(datname));

			appendStringInfo(&buf, " SET %s TO ",
							 quote_identifier(s));

			append_guc_value(&buf, s, p);

			appendStringInfoChar(&buf, ';');

			push_statement(&statements, &buf);

			pfree(s);
		}

		pfree(settings);
		pfree(nulls);
		pfree(role_settings);

		if (datname != NULL)
			pfree(datname);
	}

	systable_endscan(scan);
	table_close(rel, AccessShareLock);

	/*
	 * Scan pg_auth_members for role memberships.  We look for rows where
	 * member = roleid, meaning this role has been granted membership in other
	 * roles.
	 *
	 * A grantor needs ADMIN OPTION on the granted role already, and the
	 * only grant of ours that can supply that is a self-grant, so
	 * self-granted rows must sort last.
	 */
	if (memberships)
	{
		List	   *self_granted = NIL;

		rel = table_open(AuthMemRelationId, AccessShareLock);
		ScanKeyInit(&scankey,
					Anum_pg_auth_members_member,
					BTEqualStrategyNumber, F_OIDEQ,
					ObjectIdGetDatum(roleid));
		scan = systable_beginscan(rel, AuthMemMemRoleIndexId, true,
								  NULL, 1, &scankey);

		while (HeapTupleIsValid(tuple = systable_getnext(scan)))
		{
			Form_pg_auth_members memform = (Form_pg_auth_members) GETSTRUCT(tuple);
			char	   *granted_role;
			char	   *grantor;

			granted_role = GetUserNameFromId(memform->roleid, false);
			grantor = GetUserNameFromId(memform->grantor, false);

			appendStringInfo(&buf, "GRANT %s TO %s",
							 quote_identifier(granted_role),
							 quote_identifier(rolname));
			appendStringInfo(&buf, " WITH ADMIN %s, INHERIT %s, SET %s",
							 memform->admin_option ? "TRUE" : "FALSE",
							 memform->inherit_option ? "TRUE" : "FALSE",
							 memform->set_option ? "TRUE" : "FALSE");
			appendStringInfo(&buf, " GRANTED BY %s;",
							 quote_identifier(grantor));

			/* Self-grants wait for the grant that gave ADMIN OPTION. */
			if (memform->grantor == roleid)
				push_statement(&self_granted, &buf);
			else
				push_statement(&statements, &buf);

			pfree(granted_role);
			pfree(grantor);
		}

		systable_endscan(scan);
		table_close(rel, AccessShareLock);

		statements = list_concat(statements, self_granted);
	}

	pfree(buf.data);
	pfree(rolname);

	return statements;
}

/*
 * ddl_statements_srf
 *		Shared SRF driver for the pg_get_*_ddl() family.
 *
 * getstatements(arg) is called once, returning a List of palloc'd
 * statement strings; subsequent calls stream it out one row per call.
 */
static Datum
ddl_statements_srf(FunctionCallInfo fcinfo,
				   List *(*getstatements) (void *arg),
				   void *arg)
{
	FuncCallContext *funcctx;
	List	   *statements;

	if (SRF_IS_FIRSTCALL())
	{
		MemoryContext oldcontext;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

		statements = getstatements(arg);
		funcctx->user_fctx = statements;
		funcctx->max_calls = list_length(statements);

		MemoryContextSwitchTo(oldcontext);
	}

	funcctx = SRF_PERCALL_SETUP();
	statements = (List *) funcctx->user_fctx;

	if (funcctx->call_cntr < funcctx->max_calls)
	{
		char	   *stmt = (char *) list_nth(statements, funcctx->call_cntr);

		SRF_RETURN_NEXT(funcctx, CStringGetTextDatum(stmt));
	}

	list_free_deep(statements);
	SRF_RETURN_DONE(funcctx);
}

struct RoleDdlArgs
{
	Oid			roleid;
	bool		pretty;
	bool		memberships;
	bool		password;
	bool		in_database_settings;
};

static List *
get_role_ddl_statements(void *arg)
{
	struct RoleDdlArgs *a = (struct RoleDdlArgs *) arg;

	return pg_get_role_ddl_internal(a->roleid, a->pretty, a->memberships,
									a->password, a->in_database_settings);
}

/*
 * pg_get_role_ddl
 *		Return DDL to recreate a role as a set of text rows.
 */
Datum
pg_get_role_ddl(PG_FUNCTION_ARGS)
{
	struct RoleDdlArgs args;

	args.roleid = PG_GETARG_OID(0);
	args.pretty = PG_GETARG_BOOL(1);
	args.memberships = PG_GETARG_BOOL(2);
	args.password = PG_GETARG_BOOL(3);
	args.in_database_settings = PG_GETARG_BOOL(4);

	return ddl_statements_srf(fcinfo, get_role_ddl_statements, &args);
}

/*
 * pg_get_tablespace_ddl_internal
 *		Generate DDL statements to recreate a tablespace.
 *
 * Returns a List of palloc'd strings.  The first element is the
 * CREATE TABLESPACE statement; if the tablespace has reloptions,
 * a second element with ALTER TABLESPACE SET (...) is appended.
 */
static List *
pg_get_tablespace_ddl_internal(Oid tsid, bool pretty, bool no_owner)
{
	HeapTuple	tuple;
	Form_pg_tablespace tspForm;
	StringInfoData buf;
	char	   *spcname;
	char	   *spcowner;
	char	   *path;
	bool		isNull;
	Datum		datum;
	List	   *statements = NIL;

	tuple = SearchSysCache1(TABLESPACEOID, ObjectIdGetDatum(tsid));
	if (!HeapTupleIsValid(tuple))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("tablespace with OID %u does not exist",
						tsid)));

	tspForm = (Form_pg_tablespace) GETSTRUCT(tuple);
	spcname = pstrdup(NameStr(tspForm->spcname));

	/*
	 * Everything this emits is public by default, so what matters is
	 * catalog SELECT on pg_tablespace, not any object-specific privilege.
	 */
	if (pg_class_aclcheck(TableSpaceRelationId, GetUserId(),
						  ACL_SELECT) != ACLCHECK_OK)
	{
		ReleaseSysCache(tuple);
		aclcheck_error(ACLCHECK_NO_PRIV, OBJECT_TABLESPACE, spcname);
	}

	/* Guard against a concurrent DROP TABLESPACE, as for roles/databases. */
	shdepLockAndCheckObject(TableSpaceRelationId, tsid);

	/*
	 * We don't support generating DDL for system tablespaces.  The primary
	 * reason for this is that users shouldn't be recreating them.
	 */
	if (IsReservedName(spcname))
		ereport(ERROR,
				(errcode(ERRCODE_RESERVED_NAME),
				 errmsg("tablespace name \"%s\" is reserved", spcname),
				 errdetail("Tablespace names starting with \"pg_\" are reserved for system tablespaces.")));

	initStringInfo(&buf);

	/* Start building the CREATE TABLESPACE statement */
	appendStringInfo(&buf, "CREATE TABLESPACE %s", quote_identifier(spcname));

	/* Add OWNER clause */
	if (!no_owner)
	{
		spcowner = GetUserNameFromId(tspForm->spcowner, false);
		append_ddl_option(&buf, pretty, 4, "OWNER %s",
						  quote_identifier(spcowner));
		pfree(spcowner);
	}

	/* Find tablespace directory path */
	path = get_tablespace_location(tsid);

	/* Add directory LOCATION (path), if it exists */
	if (path[0] != '\0')
	{
		/*
		 * Special case: if the tablespace was created with GUC
		 * "allow_in_place_tablespaces = true" and "LOCATION ''", path will
		 * begin with "pg_tblspc/". In that case, show "LOCATION ''" as the
		 * user originally specified.
		 */
		if (strncmp(PG_TBLSPC_DIR_SLASH, path, strlen(PG_TBLSPC_DIR_SLASH)) == 0)
			append_ddl_option(&buf, pretty, 4, "LOCATION ''");
		else
			append_ddl_option(&buf, pretty, 4, "LOCATION %s",
							  quote_literal_cstr(path));
	}
	pfree(path);

	appendStringInfoChar(&buf, ';');
	push_statement(&statements, &buf);

	/* Check for tablespace options */
	datum = SysCacheGetAttr(TABLESPACEOID, tuple,
							Anum_pg_tablespace_spcoptions, &isNull);
	if (!isNull)
	{
		Datum	   *options;
		int			noptions;

		appendStringInfo(&buf, "ALTER TABLESPACE %s SET (",
						 quote_identifier(spcname));

		/*
		 * Elements are already "name=value", and every option is numeric,
		 * so emit verbatim, matching pg_dumpall.
		 */
		deconstruct_array_builtin(DatumGetArrayTypeP(datum), TEXTOID,
								  &options, NULL, &noptions);
		for (int i = 0; i < noptions; i++)
		{
			char	   *option = TextDatumGetCString(options[i]);

			if (i > 0)
				appendStringInfoString(&buf, ", ");
			appendStringInfoString(&buf, option);
			pfree(option);
		}
		pfree(options);

		appendStringInfoString(&buf, ");");
		push_statement(&statements, &buf);
	}

	ReleaseSysCache(tuple);
	pfree(spcname);
	pfree(buf.data);

	return statements;
}

struct TablespaceDdlArgs
{
	Oid			tsid;
	bool		pretty;
	bool		no_owner;
};

static List *
get_tablespace_ddl_statements(void *arg)
{
	struct TablespaceDdlArgs *a = (struct TablespaceDdlArgs *) arg;

	return pg_get_tablespace_ddl_internal(a->tsid, a->pretty, a->no_owner);
}

/*
 * pg_get_tablespace_ddl_srf
 *		Extract arguments and hand off to the shared SRF driver; called by
 *		both the OID- and name-based pg_get_tablespace_ddl() entry points.
 */
static Datum
pg_get_tablespace_ddl_srf(FunctionCallInfo fcinfo, Oid tsid)
{
	struct TablespaceDdlArgs args;

	args.tsid = tsid;
	args.pretty = PG_GETARG_BOOL(1);
	args.no_owner = !PG_GETARG_BOOL(2);

	return ddl_statements_srf(fcinfo, get_tablespace_ddl_statements, &args);
}

/*
 * pg_get_tablespace_ddl_oid
 *		Return DDL to recreate a tablespace, taking OID.
 */
Datum
pg_get_tablespace_ddl_oid(PG_FUNCTION_ARGS)
{
	Oid			tsid = PG_GETARG_OID(0);

	return pg_get_tablespace_ddl_srf(fcinfo, tsid);
}

/*
 * pg_get_tablespace_ddl_name
 *		Return DDL to recreate a tablespace, taking name.
 */
Datum
pg_get_tablespace_ddl_name(PG_FUNCTION_ARGS)
{
	Name		tspname = PG_GETARG_NAME(0);
	Oid			tsid = get_tablespace_oid(NameStr(*tspname), false);

	return pg_get_tablespace_ddl_srf(fcinfo, tsid);
}

/*
 * pg_get_database_ddl_internal
 *		Generate DDL statements to recreate a database.
 *
 * Returns a List of palloc'd strings.  The first element is the
 * CREATE DATABASE statement; subsequent elements are ALTER DATABASE
 * statements for properties and configuration settings.
 */
static List *
pg_get_database_ddl_internal(Oid dbid, bool pretty,
							 bool no_owner, bool no_tablespace)
{
	HeapTuple	tuple;
	Form_pg_database dbform;
	StringInfoData buf;
	bool		isnull;
	Datum		datum;
	const char *encoding;
	char	   *dbname;
	char	   *collate;
	char	   *ctype;
	Relation	rel;
	ScanKeyData scankey[2];
	SysScanDesc scan;
	List	   *statements = NIL;
	AclResult	aclresult;

	tuple = SearchSysCache1(DATABASEOID, ObjectIdGetDatum(dbid));
	if (!HeapTupleIsValid(tuple))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("database with OID %u does not exist", dbid)));

	/*
	 * User must have connect privilege for target database.  Check this
	 * before taking any lock below: a caller who can't connect to the
	 * database has no business holding a lock on it either.
	 */
	aclresult = object_aclcheck(DatabaseRelationId, dbid, GetUserId(), ACL_CONNECT);
	if (aclresult != ACLCHECK_OK)
		aclcheck_error(aclresult, OBJECT_DATABASE,
					   get_database_name(dbid));

	dbform = (Form_pg_database) GETSTRUCT(tuple);
	dbname = pstrdup(NameStr(dbform->datname));

	/*
	 * Lock and re-verify existence, closing the window for a concurrent
	 * DROP DATABASE before the scan below.
	 */
	shdepLockAndCheckObject(DatabaseRelationId, dbid);

	/*
	 * Reject invalid databases. Deparsing a pg_database row in invalid state
	 * can produce SQL that is not executable, such as CONNECTION LIMIT = -2.
	 */
	if (database_is_invalid_form(dbform))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("cannot generate DDL for invalid database \"%s\"",
						dbname)));

	/*
	 * We don't support generating DDL for system databases.  The primary
	 * reason for this is that users shouldn't be recreating them.
	 */
	if (strcmp(dbname, "template0") == 0 || strcmp(dbname, "template1") == 0)
		ereport(ERROR,
				(errcode(ERRCODE_RESERVED_NAME),
				 errmsg("database \"%s\" is a system database", dbname),
				 errdetail("DDL generation is not supported for template0 and template1.")));

	initStringInfo(&buf);

	/* --- Build CREATE DATABASE statement --- */
	appendStringInfo(&buf, "CREATE DATABASE %s", quote_identifier(dbname));

	/*
	 * Always use template0: the target database already contains the catalog
	 * data from whatever template was used originally, so we must start from
	 * the pristine template to avoid duplication.
	 */
	append_ddl_option(&buf, pretty, 4, "WITH TEMPLATE = template0");

	/* ENCODING */
	encoding = pg_encoding_to_char(dbform->encoding);
	if (strlen(encoding) > 0)
		append_ddl_option(&buf, pretty, 4, "ENCODING = %s",
						  quote_literal_cstr(encoding));

	/* LOCALE_PROVIDER */
	if (dbform->datlocprovider == COLLPROVIDER_BUILTIN ||
		dbform->datlocprovider == COLLPROVIDER_ICU ||
		dbform->datlocprovider == COLLPROVIDER_LIBC)
		append_ddl_option(&buf, pretty, 4, "LOCALE_PROVIDER = %s",
						  collprovider_name(dbform->datlocprovider));
	else
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_OBJECT_DEFINITION),
				 errmsg("unrecognized locale provider: %c",
						dbform->datlocprovider)));

	/* LOCALE, LC_COLLATE, LC_CTYPE */
	datum = SysCacheGetAttr(DATABASEOID, tuple,
							Anum_pg_database_datcollate, &isnull);
	collate = isnull ? NULL : TextDatumGetCString(datum);
	datum = SysCacheGetAttr(DATABASEOID, tuple,
							Anum_pg_database_datctype, &isnull);
	ctype = isnull ? NULL : TextDatumGetCString(datum);
	if (collate != NULL && ctype != NULL && strcmp(collate, ctype) == 0)
	{
		append_ddl_option(&buf, pretty, 4, "LOCALE = %s",
						  quote_literal_cstr(collate));
	}
	else
	{
		if (collate != NULL)
			append_ddl_option(&buf, pretty, 4, "LC_COLLATE = %s",
							  quote_literal_cstr(collate));
		if (ctype != NULL)
			append_ddl_option(&buf, pretty, 4, "LC_CTYPE = %s",
							  quote_literal_cstr(ctype));
	}

	/* LOCALE (provider-specific) */
	datum = SysCacheGetAttr(DATABASEOID, tuple,
							Anum_pg_database_datlocale, &isnull);
	if (!isnull)
	{
		const char *locale = TextDatumGetCString(datum);

		if (dbform->datlocprovider == COLLPROVIDER_BUILTIN)
			append_ddl_option(&buf, pretty, 4, "BUILTIN_LOCALE = %s",
							  quote_literal_cstr(locale));
		else if (dbform->datlocprovider == COLLPROVIDER_ICU)
			append_ddl_option(&buf, pretty, 4, "ICU_LOCALE = %s",
							  quote_literal_cstr(locale));
	}

	/* ICU_RULES */
	datum = SysCacheGetAttr(DATABASEOID, tuple,
							Anum_pg_database_daticurules, &isnull);
	if (!isnull && dbform->datlocprovider == COLLPROVIDER_ICU)
		append_ddl_option(&buf, pretty, 4, "ICU_RULES = %s",
						  quote_literal_cstr(TextDatumGetCString(datum)));

	/*
	 * TABLESPACE.  Skip the default tablespace.  Compare by OID: tablespace
	 * names are case-sensitive, so a user-defined "PG_DEFAULT" is a
	 * different, valid tablespace.
	 */
	if (!no_tablespace && OidIsValid(dbform->dattablespace) &&
		dbform->dattablespace != DEFAULTTABLESPACE_OID)
	{
		char	   *spcname = get_tablespace_name(dbform->dattablespace);

		if (spcname == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_OBJECT),
					 errmsg("tablespace with OID %u does not exist",
							dbform->dattablespace),
					 errdetail("It may have been concurrently dropped.")));

		append_ddl_option(&buf, pretty, 4, "TABLESPACE = %s",
						  quote_identifier(spcname));
	}

	appendStringInfoChar(&buf, ';');
	push_statement(&statements, &buf);

	/* OWNER */
	if (!no_owner && OidIsValid(dbform->datdba))
	{
		char	   *owner = GetUserNameFromId(dbform->datdba, false);

		appendStringInfo(&buf, "ALTER DATABASE %s OWNER TO %s;",
						 quote_identifier(dbname), quote_identifier(owner));
		pfree(owner);
		push_statement(&statements, &buf);
	}

	/* CONNECTION LIMIT */
	if (dbform->datconnlimit != -1)
	{
		appendStringInfo(&buf, "ALTER DATABASE %s CONNECTION LIMIT = %d;",
						 quote_identifier(dbname), dbform->datconnlimit);
		push_statement(&statements, &buf);
	}

	/* IS_TEMPLATE */
	if (dbform->datistemplate)
	{
		appendStringInfo(&buf, "ALTER DATABASE %s IS_TEMPLATE = true;",
						 quote_identifier(dbname));
		push_statement(&statements, &buf);
	}

	/* ALLOW_CONNECTIONS */
	if (!dbform->datallowconn)
	{
		appendStringInfo(&buf, "ALTER DATABASE %s ALLOW_CONNECTIONS = false;",
						 quote_identifier(dbname));
		push_statement(&statements, &buf);
	}

	ReleaseSysCache(tuple);

	/*
	 * Now scan pg_db_role_setting for ALTER DATABASE SET configurations.
	 *
	 * It is only database-wide (setrole = 0). It generates one ALTER
	 * statement per setting.
	 */
	rel = table_open(DbRoleSettingRelationId, AccessShareLock);
	ScanKeyInit(&scankey[0],
				Anum_pg_db_role_setting_setdatabase,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(dbid));
	ScanKeyInit(&scankey[1],
				Anum_pg_db_role_setting_setrole,
				BTEqualStrategyNumber, F_OIDEQ,
				ObjectIdGetDatum(InvalidOid));

	scan = systable_beginscan(rel, DbRoleSettingDatidRolidIndexId, true,
							  NULL, 2, scankey);

	while (HeapTupleIsValid(tuple = systable_getnext(scan)))
	{
		ArrayType  *dbconfig;
		Datum	   *settings;
		bool	   *nulls;
		int			nsettings;

		/*
		 * The setconfig column is a text array in "name=value" format. It
		 * should never be null for a valid row, but be defensive.
		 */
		datum = heap_getattr(tuple, Anum_pg_db_role_setting_setconfig,
							 RelationGetDescr(rel), &isnull);
		if (isnull)
			continue;

		dbconfig = DatumGetArrayTypePCopy(datum);

		deconstruct_array_builtin(dbconfig, TEXTOID, &settings, &nulls, &nsettings);

		for (int i = 0; i < nsettings; i++)
		{
			char	   *s,
					   *p;

			if (nulls[i])
				continue;

			s = TextDatumGetCString(settings[i]);
			p = strchr(s, '=');
			if (p == NULL)
			{
				pfree(s);
				continue;
			}
			*p++ = '\0';

			appendStringInfo(&buf, "ALTER DATABASE %s SET %s TO ",
							 quote_identifier(dbname),
							 quote_identifier(s));

			append_guc_value(&buf, s, p);

			appendStringInfoChar(&buf, ';');

			push_statement(&statements, &buf);

			pfree(s);
		}

		pfree(settings);
		pfree(nulls);
		pfree(dbconfig);
	}

	systable_endscan(scan);
	table_close(rel, AccessShareLock);

	pfree(buf.data);
	pfree(dbname);

	return statements;
}

struct DatabaseDdlArgs
{
	Oid			dbid;
	bool		pretty;
	bool		no_owner;
	bool		no_tablespace;
};

static List *
get_database_ddl_statements(void *arg)
{
	struct DatabaseDdlArgs *a = (struct DatabaseDdlArgs *) arg;

	return pg_get_database_ddl_internal(a->dbid, a->pretty, a->no_owner,
										a->no_tablespace);
}

/*
 * pg_get_database_ddl
 *		Return DDL to recreate a database as a set of text rows.
 */
Datum
pg_get_database_ddl(PG_FUNCTION_ARGS)
{
	struct DatabaseDdlArgs args;

	args.dbid = PG_GETARG_OID(0);
	args.pretty = PG_GETARG_BOOL(1);
	args.no_owner = !PG_GETARG_BOOL(2);
	args.no_tablespace = !PG_GETARG_BOOL(3);

	return ddl_statements_srf(fcinfo, get_database_ddl_statements, &args);
}

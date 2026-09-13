--
-- pg_get_role_ddl, pg_get_tablespace_ddl, pg_get_database_ddl
--
-- Converted from t/012_ddlutils.pl: none of its checks actually needed a
-- fresh backend per assertion.
--
-- Two things need pinning for a deterministic flat expected-output file:
-- SCRAM verifiers (compared as booleans against the live pg_authid value,
-- not printed) and LOCALE_PROVIDER/timezone (pinned explicitly rather than
-- filtered post hoc, as the original TAP test did).
SET timezone = 'UTC';
SET allow_in_place_tablespaces = true;

--
-- pg_get_role_ddl
--

-- Basic role: CREATE ROLE carries just the name; attributes are a
-- separate ALTER ROLE.
CREATE ROLE regress_role_ddl_test1;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_test1');

-- Replaying over an existing role: CREATE fails but the ALTER still
-- applies.  Captured into a temp table so each statement replays
-- separately -- a single multi-statement string would abort on the
-- failed CREATE and never reach the ALTER.
CREATE ROLE regress_role_ddl_exists NOLOGIN;
CREATE TEMP TABLE exists_ddl_capture AS
  SELECT stmt, ord FROM pg_get_role_ddl('regress_role_ddl_exists')
    WITH ORDINALITY AS t(stmt, ord);
ALTER ROLE regress_role_ddl_exists LOGIN CREATEDB;
SELECT stmt FROM exists_ddl_capture ORDER BY ord \gexec
SELECT rolcanlogin, rolcreatedb FROM pg_roles
  WHERE rolname = 'regress_role_ddl_exists';
DROP TABLE exists_ddl_capture;

-- Role with privileges, password, and VALID UNTIL set directly in
-- CREATE ROLE.
CREATE ROLE regress_role_ddl_test2
  LOGIN SUPERUSER CREATEDB CREATEROLE
  CONNECTION LIMIT 5
  PASSWORD 'secret'
  VALID UNTIL '2030-12-31 23:59:59+00';

-- Boolean checks, not a printed row, since it also carries PASSWORD.
SELECT stmt ~ 'SUPERUSER' AS has_superuser,
       stmt ~ 'CREATEDB' AS has_createdb,
       stmt ~ 'CONNECTION LIMIT 5' AS has_connection_limit,
       stmt ~ 'VALID UNTIL ''2030-12-31' AS has_valid_until
  FROM pg_get_role_ddl('regress_role_ddl_test2') AS t(stmt)
  WHERE stmt LIKE 'ALTER ROLE%WITH%';

-- Role without a password emits no PASSWORD clause.
SELECT NOT EXISTS (
  SELECT 1 FROM pg_get_role_ddl('regress_role_ddl_test1') AS t(stmt)
    WHERE stmt LIKE '%PASSWORD%') AS role_without_password_has_no_password_clause;

-- PASSWORD clause carries the stored verifier, compared as a boolean
-- since it's randomly salted.
SELECT EXISTS (
  SELECT 1
    FROM pg_get_role_ddl('regress_role_ddl_test2') AS t(stmt)
    JOIN pg_authid a ON a.rolname = 'regress_role_ddl_test2'
    WHERE stmt LIKE '%PASSWORD ' || quote_literal(a.rolpassword) || '%'
) AS password_clause_matches_stored_verifier;
SELECT NOT EXISTS (
  SELECT 1 FROM pg_get_role_ddl('regress_role_ddl_test2') AS t(stmt)
    WHERE stmt LIKE '%secret%') AS plaintext_password_not_exposed;

-- password => false suppresses the PASSWORD clause.
SELECT NOT EXISTS (
  SELECT 1 FROM pg_get_role_ddl('regress_role_ddl_test2', password => false) AS t(stmt)
    WHERE stmt LIKE '%PASSWORD%') AS password_suppressed;

-- Role-wide settings (test1 has no password, safe to print directly).
ALTER ROLE regress_role_ddl_test1 SET work_mem TO '256MB';
ALTER ROLE regress_role_ddl_test1 SET search_path TO myschema, public;
SELECT stmt FROM pg_get_role_ddl('regress_role_ddl_test1') AS t(stmt)
  WHERE stmt LIKE '%work_mem%' OR stmt LIKE '%search_path%'
  ORDER BY stmt;

-- Role with a database-specific setting; LOCALE_PROVIDER pinned for
-- later determinism.
CREATE DATABASE regression_ddlutils_test
  TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER libc
  LC_COLLATE 'C' LC_CTYPE 'C';
ALTER ROLE regress_role_ddl_test2
  IN DATABASE regression_ddlutils_test SET work_mem TO '128MB';
-- No PASSWORD clause on this row, safe to print directly.
SELECT stmt FROM pg_get_role_ddl('regress_role_ddl_test2') AS t(stmt)
  WHERE stmt LIKE '%IN DATABASE%';

-- Exact-shape check: each statement must be its own row, not
-- concatenated -- this would catch a buffer-reuse bug in
-- push_statement().
SELECT count(*) AS role_ddl_test2_row_count,
       count(*) FILTER (WHERE stmt ~ ';\s*\S') AS role_ddl_test2_rows_with_embedded_statement
  FROM pg_get_role_ddl('regress_role_ddl_test2') AS t(stmt);

-- in_database_settings => false drops IN DATABASE settings, keeps
-- role-wide ones.
SELECT stmt FROM pg_get_role_ddl('regress_role_ddl_test1', in_database_settings => false) AS t(stmt)
  WHERE stmt LIKE '%work_mem%';
SELECT NOT EXISTS (
  SELECT 1 FROM pg_get_role_ddl('regress_role_ddl_test2', in_database_settings => false) AS t(stmt)
    WHERE stmt LIKE '%IN DATABASE%') AS in_database_settings_false_suppresses_in_database;

-- Role with special characters (requires quoting).
CREATE ROLE "regress_role-with-dash";
SELECT * FROM pg_get_role_ddl('regress_role-with-dash');

-- Pretty-printed; boolean check again since the row carries PASSWORD.
SELECT EXISTS (
  SELECT 1 FROM pg_get_role_ddl('regress_role_ddl_test2', pretty => true) AS t(stmt)
    WHERE stmt ~ '\n\s+SUPERUSER') AS pretty_print_indents_attributes;

-- Role with memberships.
CREATE ROLE regress_role_ddl_grantor CREATEROLE;
CREATE ROLE regress_role_ddl_group1;
CREATE ROLE regress_role_ddl_group2;
CREATE ROLE regress_role_ddl_member;
GRANT regress_role_ddl_group1 TO regress_role_ddl_grantor WITH ADMIN TRUE;
GRANT regress_role_ddl_group2 TO regress_role_ddl_grantor WITH ADMIN TRUE;
SET ROLE regress_role_ddl_grantor;
GRANT regress_role_ddl_group1 TO regress_role_ddl_member
  WITH INHERIT TRUE, SET FALSE;
GRANT regress_role_ddl_group2 TO regress_role_ddl_member
  WITH ADMIN TRUE;
RESET ROLE;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_member');

-- Membership ordering: a self-grant must come after the grant that
-- gave ADMIN OPTION; the catalog scan's OID order doesn't guarantee
-- that.
CREATE ROLE regress_role_ddl_group3;
CREATE ROLE regress_role_ddl_self;
CREATE ROLE regress_role_ddl_admin CREATEROLE;
GRANT regress_role_ddl_group3 TO regress_role_ddl_admin WITH ADMIN TRUE;
SET ROLE regress_role_ddl_admin;
GRANT regress_role_ddl_group3 TO regress_role_ddl_self WITH ADMIN TRUE;
SET ROLE regress_role_ddl_self;
GRANT regress_role_ddl_group3 TO regress_role_ddl_self WITH INHERIT FALSE;
RESET ROLE;
SELECT (ord_admin IS NOT NULL AND ord_self IS NOT NULL) AS both_membership_grants_emitted,
       (ord_admin < ord_self) AS admin_grant_precedes_self_grant
  FROM (SELECT min(ord) FILTER (WHERE stmt LIKE '%GRANTED BY regress_role_ddl_admin%') AS ord_admin,
               min(ord) FILTER (WHERE stmt LIKE '%GRANTED BY regress_role_ddl_self%') AS ord_self
          FROM pg_get_role_ddl('regress_role_ddl_self') WITH ORDINALITY AS t(stmt, ord)) s;

-- That order makes the payload replayable; captured for per-statement
-- replay as above.
CREATE TEMP TABLE self_ddl_capture AS
  SELECT stmt, ord FROM pg_get_role_ddl('regress_role_ddl_self')
    WITH ORDINALITY AS t(stmt, ord);
DROP ROLE regress_role_ddl_self;
SELECT stmt FROM self_ddl_capture ORDER BY ord \gexec
DROP TABLE self_ddl_capture;

-- memberships => false suppresses GRANT statements.
SELECT NOT EXISTS (
  SELECT 1 FROM pg_get_role_ddl('regress_role_ddl_member', memberships => false) AS t(stmt)
    WHERE stmt LIKE '%GRANT%') AS memberships_suppressed;

-- Non-existent role errors.
SELECT * FROM pg_get_role_ddl(9999999::oid);

-- NULL input returns no rows.
SELECT count(*) FROM pg_get_role_ddl(NULL);

-- Needs SELECT on pg_authid even for a passwordless role, to determine
-- password status.
CREATE ROLE regress_role_ddl_noaccess;
REVOKE SELECT ON pg_authid FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_test1');
RESET ROLE;

-- password => false needs no pg_authid access; everything else is
-- public via pg_roles/pg_auth_members/pg_db_role_setting.
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_test2', password => false);
RESET ROLE;

-- Also requires pg_roles, pg_auth_members, and pg_db_role_setting,
-- unconditionally.  Revoke each individually to prove the check is a
-- real AND across all three, not satisfiable by a subset.
REVOKE SELECT ON pg_roles FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_test2', password => false);
RESET ROLE;
GRANT SELECT ON pg_roles TO PUBLIC;

REVOKE SELECT ON pg_auth_members FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_test2', password => false);
RESET ROLE;
GRANT SELECT ON pg_auth_members TO PUBLIC;

REVOKE SELECT ON pg_db_role_setting FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_test2', password => false);
RESET ROLE;
GRANT SELECT ON pg_db_role_setting TO PUBLIC;

-- Also requires pg_database before an IN DATABASE clause
-- (get_database_name() bypasses ACL checks otherwise).
-- regress_role_ddl_test2 already has an IN DATABASE setting, so this
-- exercises the real path.
REVOKE SELECT ON pg_database FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_test2', password => false);
RESET ROLE;
GRANT SELECT ON pg_database TO PUBLIC;

-- All catalogs granted: allowed.
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_role_ddl('regress_role_ddl_test2', password => false);
RESET ROLE;

--
-- pg_get_database_ddl
--

ALTER DATABASE regression_ddlutils_test OWNER TO regress_role_ddl_test2;
ALTER DATABASE regression_ddlutils_test CONNECTION LIMIT 123;
ALTER DATABASE regression_ddlutils_test SET random_page_cost = 2.0;
ALTER ROLE regress_role_ddl_test2
  IN DATABASE regression_ddlutils_test SET random_page_cost = 1.1;

-- Non-existent database errors.
SELECT * FROM pg_get_database_ddl('regression_no_such_db');

-- NULL input returns no rows.
SELECT count(*) FROM pg_get_database_ddl(NULL);

-- Invalid option (bad boolean cast) errors.
SELECT * FROM pg_get_database_ddl('regression_ddlutils_test', owner => 'invalid');

-- Duplicate named argument errors.
SELECT * FROM pg_get_database_ddl('regression_ddlutils_test', owner => false, owner => true);

-- IS_TEMPLATE/ALLOW_CONNECTIONS coverage; reset immediately so later
-- checks aren't affected.
ALTER DATABASE regression_ddlutils_test IS_TEMPLATE true;
ALTER DATABASE regression_ddlutils_test ALLOW_CONNECTIONS false;
SELECT pg_get_database_ddl FROM pg_get_database_ddl('regression_ddlutils_test');
ALTER DATABASE regression_ddlutils_test ALLOW_CONNECTIONS true;
ALTER DATABASE regression_ddlutils_test IS_TEMPLATE false;

-- Basic output; LOCALE_PROVIDER above keeps this deterministic.
SELECT pg_get_database_ddl FROM pg_get_database_ddl('regression_ddlutils_test');

-- Exact-shape check: same buffer-reuse concern as pg_get_role_ddl()
-- above.
SELECT count(*) AS database_ddl_row_count,
       count(*) FILTER (WHERE pg_get_database_ddl ~ ';\s*\S') AS database_ddl_rows_with_embedded_statement
  FROM pg_get_database_ddl('regression_ddlutils_test');

-- Pretty-printed output, without the default tablespace clause.
SELECT pg_get_database_ddl
  FROM pg_get_database_ddl('regression_ddlutils_test', pretty => true, tablespace => false);

-- Owner suppressed.
SELECT pg_get_database_ddl
  FROM pg_get_database_ddl('regression_ddlutils_test', owner => false);

-- Requires SELECT on both pg_database and pg_db_role_setting (the SET
-- rows come from the latter).
REVOKE SELECT ON pg_database FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_database_ddl('regression_ddlutils_test');
RESET ROLE;
GRANT SELECT ON pg_database TO PUBLIC;

-- Reverse case: proves the check is an AND, not an OR either catalog
-- alone would satisfy.
REVOKE SELECT ON pg_db_role_setting FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_database_ddl('regression_ddlutils_test');
RESET ROLE;
GRANT SELECT ON pg_db_role_setting TO PUBLIC;

-- Both catalogs readable: allowed.
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_database_ddl('regression_ddlutils_test');
RESET ROLE;

-- Also requires pg_roles before the OWNER clause (GetUserNameFromId()
-- bypasses ACL checks otherwise).
REVOKE SELECT ON pg_roles FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_database_ddl('regression_ddlutils_test');
RESET ROLE;
GRANT SELECT ON pg_roles TO PUBLIC;

-- Also requires pg_tablespace before a non-default TABLESPACE clause.
-- Uses a throwaway database/tablespace since regression_ddlutils_test
-- is in the default tablespace.
CREATE TABLESPACE regress_ddl_tblsp_check LOCATION '';
CREATE DATABASE regress_ddl_tblsp_check_db
  TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER libc
  LC_COLLATE 'C' LC_CTYPE 'C' TABLESPACE regress_ddl_tblsp_check;
-- Owner would otherwise default to whoever runs this script; pin it
-- for determinism.
ALTER DATABASE regress_ddl_tblsp_check_db OWNER TO regress_role_ddl_test1;
REVOKE SELECT ON pg_tablespace FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_database_ddl('regress_ddl_tblsp_check_db');
RESET ROLE;
GRANT SELECT ON pg_tablespace TO PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_database_ddl('regress_ddl_tblsp_check_db');
RESET ROLE;
DROP DATABASE regress_ddl_tblsp_check_db;
DROP TABLESPACE regress_ddl_tblsp_check;

--
-- pg_get_tablespace_ddl
--

-- Non-existent tablespace by name and by OID both error.
SELECT * FROM pg_get_tablespace_ddl('regress_nonexistent_tblsp');
SELECT * FROM pg_get_tablespace_ddl(0::oid);

-- NULL input (name and OID variants) returns no rows.
SELECT count(*) FROM pg_get_tablespace_ddl(NULL::name);
SELECT count(*) FROM pg_get_tablespace_ddl(NULL::oid);

-- Tablespace name requiring quoting.
CREATE TABLESPACE "regress_ tblsp" OWNER regress_role_ddl_test1
  LOCATION '';
SELECT * FROM pg_get_tablespace_ddl('regress_ tblsp');

-- Rename and add options; reuse for remaining tests.
ALTER TABLESPACE "regress_ tblsp" RENAME TO regress_allopt_tblsp;
ALTER TABLESPACE regress_allopt_tblsp
  SET (seq_page_cost = '1.5', random_page_cost = '1.1234567890',
       effective_io_concurrency = '17', maintenance_io_concurrency = '18');

-- Tablespace with multiple options.
SELECT * FROM pg_get_tablespace_ddl('regress_allopt_tblsp');

-- Exact-shape check: same buffer-reuse concern as above.
SELECT count(*) AS tablespace_ddl_row_count,
       count(*) FILTER (WHERE pg_get_tablespace_ddl ~ ';\s*\S') AS tablespace_ddl_rows_with_embedded_statement
  FROM pg_get_tablespace_ddl('regress_allopt_tblsp');

-- Pretty-printed output.
SELECT * FROM pg_get_tablespace_ddl('regress_allopt_tblsp', pretty => true);

-- Owner suppressed.
SELECT * FROM pg_get_tablespace_ddl('regress_allopt_tblsp', owner => false);

-- Lookup by OID.
SELECT pg_get_tablespace_ddl
  FROM pg_get_tablespace_ddl(
    (SELECT oid FROM pg_tablespace WHERE spcname = 'regress_allopt_tblsp'));

-- Requires catalog-wide SELECT on pg_tablespace.
REVOKE SELECT ON pg_tablespace FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_tablespace_ddl('regress_allopt_tblsp');
RESET ROLE;
GRANT SELECT ON pg_tablespace TO PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_tablespace_ddl('regress_allopt_tblsp');
RESET ROLE;

-- Also requires pg_roles before the OWNER clause.
REVOKE SELECT ON pg_roles FROM PUBLIC;
SET ROLE regress_role_ddl_noaccess;
SELECT * FROM pg_get_tablespace_ddl('regress_allopt_tblsp');
RESET ROLE;
GRANT SELECT ON pg_roles TO PUBLIC;

-- Cleanup.
DROP TABLESPACE regress_allopt_tblsp;
DROP DATABASE regression_ddlutils_test;
DROP ROLE regress_role_ddl_test1, regress_role_ddl_test2, regress_role_ddl_exists,
          regress_role_ddl_noaccess, regress_role_ddl_grantor, regress_role_ddl_group1,
          regress_role_ddl_group2, regress_role_ddl_member, regress_role_ddl_group3,
          regress_role_ddl_self, regress_role_ddl_admin, "regress_role-with-dash";

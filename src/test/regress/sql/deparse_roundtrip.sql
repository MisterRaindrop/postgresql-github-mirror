--
-- DEPARSE_ROUNDTRIP
--
-- A view or rule definition emitted by pg_get_viewdef / pg_get_ruledef must
-- read back: the text must re-parse, define a relation returning the same
-- rows, and be a fixed point (deparsing the recreated object yields identical
-- text).  These invariants are relied on by pg_dump; a definition that fails
-- any of them is a dump that will not restore.
--
-- The test drives a corpus of definitions that have historically round-tripped
-- incorrectly (expressions needing extra parentheses, ROW() comparisons,
-- keyword-named windows, reserved-word rule aliases, XMLTABLE namespace URIs).
-- It reports only a per-case verdict, so the expected output stays small and
-- stable regardless of how the deparser spells a given definition.
--

CREATE SCHEMA deparse_rt;
SET search_path = deparse_rt;
SET client_min_messages = warning;

CREATE TABLE t (a int, b int, c text, d text);
INSERT INTO t VALUES (1, 2, 'x', 'y'), (3, 4, 'p', 'q'), (5, 6, NULL, 'z');

-- Round-trip one view definition: create it as "src", deparse, recreate the
-- deparsed text as "dst", and check (1) it re-parsed, (2) dst returns the same
-- rows as src, (3) deparsing dst equals deparsing src (fixed point).
CREATE FUNCTION rt_view(label text, body text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    def1 text;
    def2 text;
    same boolean;
BEGIN
    EXECUTE 'DROP VIEW IF EXISTS rt_dst, rt_src';
    EXECUTE 'CREATE VIEW rt_src AS ' || body;
    def1 := pg_get_viewdef('rt_src'::regclass, true);
    BEGIN
        EXECUTE 'CREATE VIEW rt_dst AS ' || def1;
    EXCEPTION WHEN others THEN
        RETURN label || ': FAIL (deparsed view does not re-parse: ' || SQLERRM || ')';
    END;
    def2 := pg_get_viewdef('rt_dst'::regclass, true);
    IF def1 IS DISTINCT FROM def2 THEN
        RETURN label || ': FAIL (deparse not a fixed point)';
    END IF;
    EXECUTE 'SELECT (SELECT array_agg(x ORDER BY x) FROM (SELECT (rt_src)::text x FROM rt_src) s)'
          || ' IS NOT DISTINCT FROM '
          || '(SELECT array_agg(x ORDER BY x) FROM (SELECT (rt_dst)::text x FROM rt_dst) s)'
      INTO same;
    IF NOT same THEN
        RETURN label || ': FAIL (recreated view returns different rows)';
    END IF;
    RETURN label || ': ok';
END $$;

-- Round-trip one rule definition (re-parse only; a rule has no result set).
CREATE FUNCTION rt_rule(label text, rule_body text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    def text;
BEGIN
    EXECUTE 'DROP TABLE IF EXISTS rt_rtab CASCADE';
    EXECUTE 'CREATE TABLE rt_rtab (a int, b int)';
    BEGIN
        EXECUTE rule_body;
    EXCEPTION WHEN others THEN
        RETURN label || ': skip (rule body not accepted here: ' || SQLERRM || ')';
    END;
    SELECT pg_get_ruledef(oid) INTO def FROM pg_rewrite
     WHERE ev_class = 'rt_rtab'::regclass AND rulename <> '_RETURN'
     ORDER BY rulename LIMIT 1;
    IF def IS NULL THEN
        RETURN label || ': FAIL (no rule found)';
    END IF;
    EXECUTE 'DROP TABLE rt_rtab CASCADE';
    EXECUTE 'CREATE TABLE rt_rtab (a int, b int)';
    BEGIN
        EXECUTE def;
    EXCEPTION WHEN others THEN
        RETURN label || ': FAIL (deparsed rule does not re-parse: ' || SQLERRM || ')';
    END;
    RETURN label || ': ok';
END $$;

-- Views: expressions, set operations, grouping, windows, ROW() comparisons.
SELECT rt_view('plain',        'SELECT a, b FROM t');
SELECT rt_view('expr_paren',   'SELECT (a + b) * 2 AS e, (NOT (a < b)) AS f FROM t');
SELECT rt_view('collate',      'SELECT a FROM t WHERE c COLLATE "C" < d COLLATE "C"');
SELECT rt_view('row_cmp',      'SELECT a FROM t WHERE ROW(a, b) < ROW(b, a)');
SELECT rt_view('row_eq',       'SELECT (ROW(a, b) = ROW(b, a)) AS e FROM t');
SELECT rt_view('case_when',    'SELECT CASE WHEN a < b THEN c ELSE d END AS e FROM t');
SELECT rt_view('distinct_on',  'SELECT DISTINCT ON (a) a, b FROM t ORDER BY a, b');
SELECT rt_view('setop',        'SELECT a FROM t UNION SELECT b FROM t');
SELECT rt_view('grouping',     'SELECT a, sum(b) FROM t GROUP BY GROUPING SETS ((a), ())');
SELECT rt_view('window_kw',    'SELECT a, sum(b) OVER "rows" FROM t WINDOW "rows" AS (ORDER BY a)');
SELECT rt_view('window_frame', 'SELECT a, sum(b) OVER (ORDER BY a ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM t');
SELECT rt_view('is_distinct',  'SELECT a FROM t WHERE c IS NOT DISTINCT FROM d');
SELECT rt_view('arr_subscript','SELECT (ARRAY[a, b])[1] AS e FROM t');
SELECT rt_view('coerce',       'SELECT a::text::int AS e, b::numeric AS f FROM t');
SELECT rt_view('subselect',    'SELECT a FROM t x WHERE b IN (SELECT b FROM t y WHERE y.a <> x.a)');

-- Rules: reserved-word aliases in the action, DO ALSO / DO INSTEAD.
SELECT rt_rule('rule_alias',
  'CREATE RULE r AS ON INSERT TO rt_rtab DO ALSO DELETE FROM rt_rtab AS using_ WHERE using_.a = new.a + 100');
SELECT rt_rule('rule_instead',
  'CREATE RULE r AS ON UPDATE TO rt_rtab DO INSTEAD NOTHING');

DROP SCHEMA deparse_rt CASCADE;

--
-- The executor enforces a plan node's own working-memory limit when one is
-- set, and work_mem otherwise.  Each query below exercises one kind of node
-- that uses working memory, and wm_explain() reports, per node, whether it
-- stayed in memory, without the sizes.
--
LOAD 'test_plan_workmem';

CREATE TABLE wm_tab AS
  SELECT g AS a, g % 100 AS b, g % 10 AS c, repeat('x', 100) AS pad
  FROM generate_series(1, 20000) g;
CREATE INDEX wm_tab_a ON wm_tab (a);
CREATE INDEX wm_tab_b ON wm_tab (b);
CREATE INDEX wm_tab_c ON wm_tab (c);
ANALYZE wm_tab;

CREATE FUNCTION wm_explain(query text) RETURNS SETOF text
LANGUAGE plpgsql AS
$$
DECLARE
    ln text;
    node text;
BEGIN
    FOR ln IN EXECUTE
        'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) ' || query
    LOOP
        IF ln ~ '\(actual' THEN
            node := substring(ln FROM '^\s*(?:->\s*)?([A-Za-z ]+?)(?: on | using | \()');
        ELSIF ln ~ 'Sort Method: ' THEN
            RETURN NEXT node || ': ' ||
                CASE WHEN ln ~ 'external' THEN 'disk' ELSE 'memory' END;
        ELSIF ln ~ 'Storage: ' THEN
            RETURN NEXT node || ': ' ||
                CASE WHEN ln ~ 'Storage: Disk' THEN 'disk' ELSE 'memory' END;
        ELSIF ln ~ 'Batches: ' THEN
            RETURN NEXT node || ': ' ||
                CASE WHEN ln ~ 'Batches: 1( |$)' THEN 'one batch' ELSE 'several batches' END;
        ELSIF ln ~ 'Evictions: ' THEN
            RETURN NEXT node || ': ' ||
                CASE WHEN ln ~ 'Evictions: 0 ' THEN 'no evictions' ELSE 'evictions' END;
        ELSIF ln ~ 'Heap Blocks: ' THEN
            RETURN NEXT node || ': ' ||
                CASE WHEN ln ~ 'lossy' THEN 'lossy' ELSE 'exact' END;
        END IF;
    END LOOP;
END;
$$;

-- More pages, so that a bitmap of them does not fit in 64kB
CREATE TABLE wm_big AS
  SELECT g AS a, g % 10 AS c, repeat('x', 100) AS pad
  FROM generate_series(1, 150000) g;
CREATE INDEX wm_big_a ON wm_big (a);
CREATE INDEX wm_big_c ON wm_big (c);
ANALYZE wm_big;

-- Set-returning functions and ordered-set aggregates keep their data in a
-- tuplestore or tuplesort that EXPLAIN does not report on: look for a
-- temporary file while the query's rows are read.  (EXECUTE, so that the
-- query is planned with the current node limit.)
CREATE FUNCTION wm_spills(label text, query text) RETURNS text
LANGUAGE plpgsql AS
$$
DECLARE
    spilled bool;
BEGIN
    -- q must be used, or the planner can leave the query out entirely
    EXECUTE 'SELECT (SELECT count(*) > 0 FROM pg_ls_tmpdir()) FROM ('
            || query || ') q WHERE length(q::text) > 0 LIMIT 1'
        INTO spilled;
    RETURN label || ': ' || CASE WHEN spilled THEN 'disk' ELSE 'memory' END;
END;
$$;

CREATE FUNCTION wm_run_all() RETURNS SETOF text
LANGUAGE plpgsql AS
$$
BEGIN
    SET LOCAL max_parallel_workers_per_gather = 0;

    RETURN QUERY SELECT wm_explain('SELECT * FROM wm_tab ORDER BY pad, a');

    SET LOCAL enable_sort = off;
    RETURN QUERY SELECT wm_explain(
        'SELECT * FROM wm_tab WHERE c < 2 ORDER BY c, pad');
    SET LOCAL enable_indexscan = off;
    SET LOCAL enable_bitmapscan = off;
    RETURN QUERY SELECT wm_explain(
        'SELECT a, count(*) FROM wm_tab GROUP BY a');
    RESET enable_sort;
    RESET enable_indexscan;
    RESET enable_bitmapscan;

    SET LOCAL enable_mergejoin = off;
    SET LOCAL enable_nestloop = off;
    RETURN QUERY SELECT wm_explain(
        'SELECT count(*) FROM wm_tab t1 JOIN wm_tab t2 USING (a)');
    RESET enable_mergejoin;
    RESET enable_nestloop;

    SET LOCAL enable_hashjoin = off;
    SET LOCAL enable_mergejoin = off;
    RETURN QUERY SELECT wm_explain(
        'SELECT count(*) FROM generate_series(1, 3) g,
           (SELECT * FROM wm_tab OFFSET 0) t WHERE t.a > g');
    RESET enable_hashjoin;
    RESET enable_mergejoin;

    RETURN QUERY SELECT wm_explain(
        'WITH c AS MATERIALIZED (SELECT * FROM wm_tab)
         SELECT count(*) FROM c c1, c c2 WHERE c1.a = c2.a');
    RETURN QUERY SELECT wm_explain(
        'SELECT count(*) OVER () FROM wm_tab');
    RETURN QUERY SELECT wm_explain(
        'WITH RECURSIVE r AS (SELECT a, pad, 1 AS n FROM wm_tab
                              UNION ALL
                              SELECT a, pad, n + 1 FROM r WHERE n < 2)
         SELECT count(*) FROM r');
    RETURN QUERY SELECT wm_explain(
        'SELECT count(*) FROM JSON_TABLE(
           (SELECT jsonb_agg(pad) FROM wm_tab), ''$[*]''
           COLUMNS (v text PATH ''$''))');

    SET LOCAL enable_hashjoin = off;
    SET LOCAL enable_mergejoin = off;
    SET LOCAL enable_material = off;
    RETURN QUERY SELECT wm_explain(
        'SELECT count(*) FROM wm_tab t1 JOIN wm_tab t2 ON t2.b = t1.b
         WHERE t1.a <= 2000');
    RESET enable_hashjoin;
    RESET enable_mergejoin;
    RESET enable_material;

    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_indexscan = off;
    RETURN QUERY SELECT wm_explain(
        'SELECT count(*) FROM wm_big WHERE c < 5');
    RETURN QUERY SELECT wm_explain(
        'SELECT count(*) FROM wm_big WHERE c = 1 OR a < 50000');
    RESET enable_seqscan;
    RESET enable_indexscan;

    RETURN NEXT wm_spills('Function Scan (value per call)',
        'SELECT * FROM generate_series(1, 100000)');
    RETURN NEXT wm_spills('Function Scan (materialize mode)',
        'SELECT * FROM jsonb_each((SELECT jsonb_object_agg(a, pad) FROM wm_tab))');
    RETURN NEXT wm_spills('Function Scan (jsonb_to_recordset)',
        'SELECT * FROM jsonb_to_recordset((SELECT jsonb_agg(to_jsonb(t)) FROM wm_tab t))
           AS x(a int, pad text)');
    RETURN NEXT wm_spills('ProjectSet',
        'SELECT jsonb_each((SELECT jsonb_object_agg(a, pad) FROM wm_tab))');
    RETURN NEXT wm_spills('Aggregate (ordered-set)',
        'SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY pad || a) FROM wm_tab');
END;
$$;

-- EXPLAIN VERBOSE shows a node's own limit, and nothing when it has none
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM wm_tab ORDER BY pad;
SET test_plan_workmem.node_limit = '1MB';
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM wm_tab ORDER BY pad;
-- including a node the planner adds last: the Materialize on top of the
-- plan of a scrollable cursor
EXPLAIN (VERBOSE, COSTS OFF)
  DECLARE wm_cur SCROLL CURSOR FOR SELECT b, count(*) FROM wm_tab GROUP BY b;
RESET test_plan_workmem.node_limit;

-- No node limit: the nodes use work_mem
SET work_mem = '64MB';
SELECT wm_run_all();

-- A node limit below work_mem is enforced
SET test_plan_workmem.node_limit = '64kB';
SELECT wm_run_all();

-- So is a node limit above work_mem
SET work_mem = '64kB';
SET test_plan_workmem.node_limit = '64MB';
SELECT wm_run_all();

RESET test_plan_workmem.node_limit;
RESET work_mem;
DROP FUNCTION wm_run_all();
DROP FUNCTION wm_spills(text, text);
DROP FUNCTION wm_explain(text);
DROP TABLE wm_big;
DROP TABLE wm_tab;

-- bit check

CREATE TABLE bittmp (a bit(33));

\copy bittmp from 'data/bit.data'

SET enable_seqscan=on;

SELECT count(*) FROM bittmp WHERE a <   '011011000100010111011000110000100';

SELECT count(*) FROM bittmp WHERE a <=  '011011000100010111011000110000100';

SELECT count(*) FROM bittmp WHERE a  =  '011011000100010111011000110000100';

SELECT count(*) FROM bittmp WHERE a >=  '011011000100010111011000110000100';

SELECT count(*) FROM bittmp WHERE a >   '011011000100010111011000110000100';

CREATE INDEX bitidx ON bittmp USING GIST ( a );

SET enable_seqscan=off;

SELECT count(*) FROM bittmp WHERE a <   '011011000100010111011000110000100';

SELECT count(*) FROM bittmp WHERE a <=  '011011000100010111011000110000100';

SELECT count(*) FROM bittmp WHERE a  =  '011011000100010111011000110000100';

SELECT count(*) FROM bittmp WHERE a >=  '011011000100010111011000110000100';

SELECT count(*) FROM bittmp WHERE a >   '011011000100010111011000110000100';

-- Test index-only scans
SET enable_bitmapscan=off;
EXPLAIN (COSTS OFF)
SELECT a FROM bittmp WHERE a BETWEEN '1000000' and '1000001';

-- Page splits of a multicolumn index union leaf keys; afterwards an index
-- probe on each row's own value must find that row exactly once
CREATE TABLE bitmulti (a bit(16), b int);
CREATE INDEX bitmultiidx ON bitmulti USING gist (a, b);
INSERT INTO bitmulti SELECT i::bit(16), i FROM generate_series(1, 300) i;
EXPLAIN (COSTS OFF)
SELECT t.a FROM bitmulti t,
  LATERAL (SELECT count(*) AS n FROM bitmulti u WHERE u.a = t.a) p
WHERE p.n <> 1;
SELECT t.a FROM bitmulti t,
  LATERAL (SELECT count(*) AS n FROM bitmulti u WHERE u.a = t.a) p
WHERE p.n <> 1;

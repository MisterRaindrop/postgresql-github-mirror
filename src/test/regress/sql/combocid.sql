--
-- Tests for some likely failure cases with combo cmin/cmax mechanism
--
CREATE TEMP TABLE combocidtest (foobar int);

BEGIN;

-- a few dummy ops to push up the CommandId counter
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;

INSERT INTO combocidtest VALUES (1);
INSERT INTO combocidtest VALUES (2);

SELECT ctid,cmin,* FROM combocidtest;

SAVEPOINT s1;

UPDATE combocidtest SET foobar = foobar + 10;

-- here we should see only updated tuples
SELECT ctid,cmin,* FROM combocidtest;

ROLLBACK TO s1;

-- now we should see old tuples, but with combo CIDs starting at 0
SELECT ctid,cmin,* FROM combocidtest;

COMMIT;

-- combo data is not there anymore, but should still see tuples
SELECT ctid,cmin,* FROM combocidtest;

-- Test combo CIDs with portals
BEGIN;

INSERT INTO combocidtest VALUES (333);

DECLARE c CURSOR FOR SELECT ctid,cmin,* FROM combocidtest;

DELETE FROM combocidtest;

FETCH ALL FROM c;

ROLLBACK;

SELECT ctid,cmin,* FROM combocidtest;

-- check behavior with locked tuples
BEGIN;

-- a few dummy ops to push up the CommandId counter
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;
INSERT INTO combocidtest SELECT 1 LIMIT 0;

INSERT INTO combocidtest VALUES (444);

SELECT ctid,cmin,* FROM combocidtest;

SAVEPOINT s1;

-- this doesn't affect cmin
SELECT ctid,cmin,* FROM combocidtest FOR UPDATE;
SELECT ctid,cmin,* FROM combocidtest;

-- but this does
UPDATE combocidtest SET foobar = foobar + 10;

SELECT ctid,cmin,* FROM combocidtest;

ROLLBACK TO s1;

SELECT ctid,cmin,* FROM combocidtest;

COMMIT;

SELECT ctid,cmin,* FROM combocidtest;

-- test for bug reported in
-- CABRT9RC81YUf1=jsmWopcKJEro=VoeG2ou6sPwyOUTx_qteRsg@mail.gmail.com
CREATE TABLE IF NOT EXISTS testcase(
	id int PRIMARY KEY,
	balance numeric
);
INSERT INTO testcase VALUES (1, 0);
BEGIN;
SELECT * FROM testcase WHERE testcase.id = 1 FOR UPDATE;
UPDATE testcase SET balance = balance + 400 WHERE id=1;
SAVEPOINT subxact;
UPDATE testcase SET balance = balance - 100 WHERE id=1;
ROLLBACK TO SAVEPOINT subxact;
-- should return one tuple
SELECT * FROM testcase WHERE id = 1 FOR UPDATE;
ROLLBACK;
DROP TABLE testcase;

-- An UPDATE that must release the buffer lock (because the new tuple needs
-- toasting or does not fit on the page) first marks the old tuple as locked.
-- That lock-only Xmax must not keep the update of a rolled-back
-- subtransaction, even when the updating transaction already holds the
-- same row lock.
CREATE TABLE testcase(
	id int PRIMARY KEY,
	val text
);
INSERT INTO testcase VALUES (1, '');
BEGIN;
SELECT id FROM testcase WHERE id = 1 FOR NO KEY UPDATE;
SAVEPOINT subxact;
UPDATE testcase SET val = 'subxact' WHERE id = 1;
ROLLBACK TO SAVEPOINT subxact;
RELEASE SAVEPOINT subxact;
UPDATE testcase SET val = repeat('x', 3000) WHERE id = 1;
SELECT id, length(val) FROM testcase;
COMMIT;
-- same with FOR UPDATE and a key update
BEGIN;
SELECT id FROM testcase WHERE id = 1 FOR UPDATE;
SAVEPOINT subxact;
UPDATE testcase SET val = 'subxact' WHERE id = 1;
ROLLBACK TO SAVEPOINT subxact;
RELEASE SAVEPOINT subxact;
UPDATE testcase SET id = 2, val = repeat('y', 3000) WHERE id = 1;
SELECT id, length(val) FROM testcase;
COMMIT;
-- the new tuple version inherits the Xmax of the old one; a later update of
-- that version must not trip over the rolled-back update either
BEGIN;
SELECT id FROM testcase WHERE id = 2 FOR NO KEY UPDATE;
SAVEPOINT subxact;
UPDATE testcase SET val = 'subxact' WHERE id = 2;
ROLLBACK TO SAVEPOINT subxact;
RELEASE SAVEPOINT subxact;
UPDATE testcase SET val = 'small' WHERE id = 2;
UPDATE testcase SET val = repeat('z', 3000) WHERE id = 2;
SELECT id, length(val) FROM testcase;
COMMIT;
DROP TABLE testcase;

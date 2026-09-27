--
-- Test the error context reported while vacuum processes an index, in
-- particular by the leader of a parallel vacuum.
--
set client_min_messages TO 'warning';
create extension if not exists injection_points;
reset client_min_messages;

-- Wait until the deleted tuples are removable, so that vacuum really gets to
-- delete an index page. Same as in nbtree_half_dead_pages, which runs in the
-- same database.
CREATE OR REPLACE PROCEDURE wait_prunable() LANGUAGE plpgsql AS $$
	DECLARE
		barrier xid8;
		cutoff xid8;
	BEGIN
		barrier := pg_current_xact_id();
		LOOP
			ROLLBACK;  -- release MyProc->xmin, which could be the oldest
			cutoff := removable_cutoff('pg_database');
			EXIT WHEN cutoff >= barrier;
			PERFORM pg_sleep(.1);
		END LOOP;
	END
$$;

SELECT injection_points_set_local();

create table nbtree_vacuum_error_context(id bigint, id2 bigint)
  with (autovacuum_enabled = off);

insert into nbtree_vacuum_error_context
  select g, g from generate_series(1, 30000) g;

-- Parallel vacuum needs more than one index
create index nbtree_vacuum_error_context_idx
  on nbtree_vacuum_error_context (id);
create index nbtree_vacuum_error_context_idx2
  on nbtree_vacuum_error_context (id2);

-- Empty out whole leaf pages, so that vacuum deletes them. The range has to
-- be wide enough to cover a leaf page on a large block size build too.
delete from nbtree_vacuum_error_context where id > 10000 and id < 20000;
call wait_prunable();

-- Error out in the middle of the index scan performed by vacuum
SELECT injection_points_attach('nbtree-leave-page-half-dead', 'error');

VACUUM (PARALLEL 0) nbtree_vacuum_error_context;

-- min_parallel_index_scan_size makes the small indexes eligible for parallel
-- vacuum, and max_parallel_workers leaves no worker to launch, so the leader
-- processes the indexes itself
SET min_parallel_index_scan_size = 0;
SET max_parallel_workers = 0;
VACUUM (PARALLEL 1) nbtree_vacuum_error_context;

SELECT injection_points_detach('nbtree-leave-page-half-dead');
drop extension injection_points;

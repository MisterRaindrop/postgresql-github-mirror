setup {
	CREATE EXTENSION IF NOT EXISTS injection_points;

	create table repack_dropped (id int primary key, a text, b text);
	alter table repack_dropped alter column b set storage external;
	insert into repack_dropped select g, cash_words(g::money), repeat(cash_words(g::money), 10 * g) from generate_series(10, 100) g;
	create function repack_dropped_f() returns trigger language plpgsql as $$ begin return OLD; end $$;
	create trigger repack_dropped_t before update on repack_dropped for each row execute function repack_dropped_f();
	alter table repack_dropped drop column b;
}

teardown {
	drop table repack_dropped;
	drop function repack_dropped_f;
}

session s1

step s1_size
{
	select pg_relation_size(oid), pg_relation_size(reltoastrelid) from pg_class where relname = 'repack_dropped';
}

step s1_unlock
{
	SELECT injection_points_wakeup('repack-concurrently-before-lock');
}

session s2
setup
{
	SELECT injection_points_set_local();
	SELECT injection_points_attach('repack-concurrently-before-lock', 'wait');
}

step s2_repack
{
	repack (concurrently) repack_dropped;
}

session s3
step s3_updates
{
	update repack_dropped set a = a || a;
}

permutation
	s1_size
	s2_repack
	s3_updates
	s1_unlock
	s1_size

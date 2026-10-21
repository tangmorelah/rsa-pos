-- RSA - POS Assistant : lock every function away from the browser except the five entry points (runs last)
-- Only the five entry points are callable from the browser.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'rsa%' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', r.sig); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke all on function %s from authenticated', r.sig); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function rsa_status() to anon;
    grant execute on function rsa_setup(text, text, text) to anon;
    grant execute on function rsa_login(text, text) to anon;
    grant execute on function rsa_logout(text) to anon;
    grant execute on function rsa_api(text, text, jsonb) to anon;
  end if;
end $$;

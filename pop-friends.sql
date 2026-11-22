-- Pop friends ladders: direct, mutual friendships that never chain.
-- Paste all of this into Supabase > SQL Editor > New query, then press Run. Safe to run again.
--
-- * Every player gets a friend code (8 characters, shown as POP-XXXX-XXXX).
-- * A friendship is one row for a pair of players, stored once (smaller id first), so it is mutual by design.
-- * Sharing your code or invite link is permission for someone to add you. Adding always shows the name first.
-- * Up to 200 friends each, checked for both players, even when two adds happen at once.
-- * Removing a friend is silent and removes it both ways.

-- 1. friend codes
alter table public.players add column if not exists code text;
create unique index if not exists players_code_unique on public.players (code);

create or replace function public.pop_new_code()
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; b bytea;
begin
  loop
    b := extensions.gen_random_bytes(8); c := '';
    for k in 0..7 loop c := c || substr(a, (get_byte(b, k) % 32) + 1, 1); end loop;
    exit when not exists (select 1 from public.players where code = c);
  end loop;
  return c;
end $$;
revoke all on function public.pop_new_code() from public, anon, authenticated;

update public.players set code = public.pop_new_code() where code is null;

-- tidy what people type: "pop-7k2q-m9tx", "7K2Q M9TX" and "POP7K2QM9TX" all become 7K2QM9TX
create or replace function public.pop_clean_code(p text)
returns text language sql immutable set search_path = public as $$
  select regexp_replace(regexp_replace(upper(coalesce(p, '')), '^\s*POP', ''), '[^A-Z0-9]', '', 'g')
$$;

-- 2. friendships
create table if not exists public.friendships (
  a uuid not null references public.players(id) on delete cascade,
  b uuid not null references public.players(id) on delete cascade,
  via text not null default 'code',
  created_at timestamptz not null default now(),
  primary key (a, b),
  check (a < b)
);
create index if not exists friendships_b_idx on public.friendships (b);
alter table public.friendships enable row level security;
revoke all on table public.friendships from anon, authenticated;

-- 3. your own friend code (made on first ask)
create or replace function public.pop_my_code(p_id uuid, p_token text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare me public.players;
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  if me.code is null then update public.players set code = public.pop_new_code() where id = me.id returning code into me.code; end if;
  return me.code;
end $$;

-- 4. who a code belongs to (just their ladder name), so the game can ask "Add Mark R?" before connecting
create or replace function public.pop_lookup_code(p_code text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('name', name) from public.players where code = public.pop_clean_code(p_code) and not hidden
$$;

-- 5. you + your friends, ranked
create or replace function public.pop_friends(p_id uuid, p_token text)
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare me public.players; out json;
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  with f as (
    select case when a = me.id then b else a end as id from public.friendships where a = me.id or b = me.id
  ), people as (
    select p.id, p.name, p.best, p.id = me.id as you from public.players p where p.id = me.id or p.id in (select id from f)
  ), r as (
    select id, name, best, you, rank() over (order by best desc) as rank, row_number() over (order by best desc, name) as rn from people
  )
  select json_build_object(
    'count', (select count(*) from r),
    'friends', (select count(*) from f),
    'me', (select json_build_object('rank', rank) from r where you),
    'rows', coalesce((select json_agg(json_build_object('id', id, 'name', name, 'best', best, 'rank', rank, 'you', you) order by rn) from r), '[]'::json)
  ) into out;
  return out;
end $$;

-- 6. add a friend by their code (the game always shows their name and an Add button first)
create or replace function public.pop_add_friend(p_id uuid, p_token text, p_code text, p_via text default 'code')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me public.players; them public.players; lo uuid; hi uuid; cap int := 200;
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  select * into them from public.players where code = public.pop_clean_code(p_code) and not hidden;
  if them.id is null then raise exception 'no_such_code'; end if;
  if them.id = me.id then raise exception 'thats_you'; end if;
  lo := least(me.id, them.id); hi := greatest(me.id, them.id);
  -- lock both players in a fixed order so two adds at once can't both slip past the limit
  perform 1 from public.players where id in (lo, hi) order by id for update;
  if exists (select 1 from public.friendships where a = lo and b = hi) then return public.pop_friends(p_id, p_token); end if;
  if (select count(*) from public.friendships where a = me.id or b = me.id) >= cap then raise exception 'you_are_full'; end if;
  if (select count(*) from public.friendships where a = them.id or b = them.id) >= cap then raise exception 'they_are_full'; end if;
  insert into public.friendships (a, b, via) values (lo, hi, case when p_via = 'link' then 'link' else 'code' end) on conflict do nothing;
  return public.pop_friends(p_id, p_token);
end $$;

-- 7. remove a friend (silent, both ways)
create or replace function public.pop_remove_friend(p_id uuid, p_token text, p_friend uuid)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me public.players;
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  delete from public.friendships where a = least(me.id, p_friend) and b = greatest(me.id, p_friend);
  return public.pop_friends(p_id, p_token);
end $$;

-- new players get a code straight away
create or replace function public.pop_code_on_insert() returns trigger language plpgsql security definer set search_path = public as $$
begin if new.code is null then new.code := public.pop_new_code(); end if; return new; end $$;
drop trigger if exists players_code_trg on public.players;
create trigger players_code_trg before insert on public.players for each row execute function public.pop_code_on_insert();

grant execute on function public.pop_my_code(uuid, text) to anon, authenticated;
grant execute on function public.pop_lookup_code(text) to anon, authenticated;
grant execute on function public.pop_friends(uuid, text) to anon, authenticated;
grant execute on function public.pop_add_friend(uuid, text, text, text) to anon, authenticated;
grant execute on function public.pop_remove_friend(uuid, text, uuid) to anon, authenticated;

-- Pop ladder: players, best scores and the leaderboard.
-- Paste all of this into Supabase > SQL Editor > New query, then press Run. Safe to run again.
--
-- How it's protected:
--  * Nobody can read or write the table directly. The game can only call the four pop_ functions below.
--  * Each player gets a random secret key when they enter their name. Only a fingerprint (hash) of it
--    is stored, so even the database can't hand it out. Scores and renames need that key.
--  * Scores are checked for sense (no negatives, no absurd jumps, a short cool-down between sends).
--    Full move-by-move checking comes later, before Pop is opened to the public.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.players (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 2 and 20),
  token_hash  text not null,
  best        integer not null default 0 check (best >= 0),
  best_at     timestamptz,
  games       integer not null default 0,
  last_submit timestamptz,
  hidden      boolean not null default false,   -- set true by hand to take someone off the ladder
  created_at  timestamptz not null default now()
);
create index if not exists players_ladder_idx on public.players (best desc, best_at asc) where not hidden and best > 0;

alter table public.players enable row level security;
revoke all on table public.players from anon, authenticated;

-- the player behind an id + secret key, or nothing
create or replace function public.pop_me(p_id uuid, p_token text)
returns public.players language sql stable security definer set search_path = public, extensions as $$
  select * from public.players
  where id = p_id and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;
revoke all on function public.pop_me(uuid, text) from public, anon, authenticated;

create or replace function public.pop_clean_name(p_name text)
returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'))
$$;

-- New player: returns their id and secret key (the phone keeps both).
create or replace function public.pop_register(p_name text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  nm  text := public.pop_clean_name(p_name);
  tok text := encode(extensions.gen_random_bytes(24), 'hex');
  pid uuid;
begin
  if char_length(nm) < 2 or char_length(nm) > 20 then raise exception 'bad_name'; end if;
  if (select count(*) from public.players where created_at > now() - interval '1 minute') >= 30 then
    raise exception 'busy';   -- flood guard: at most 30 new players a minute
  end if;
  insert into public.players (name, token_hash)
  values (nm, encode(extensions.digest(tok, 'sha256'), 'hex'))
  returning id into pid;
  return json_build_object('id', pid, 'token', tok, 'name', nm);
end $$;

-- Change your display name.
create or replace function public.pop_rename(p_id uuid, p_token text, p_name text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me public.players; nm text := public.pop_clean_name(p_name);
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  if char_length(nm) < 2 or char_length(nm) > 20 then raise exception 'bad_name'; end if;
  update public.players set name = nm where id = me.id;
  return public.pop_board(p_id, p_token);
end $$;

-- Send a finished (or still running) game's score. Keeps the higher of old best and this score.
create or replace function public.pop_score(p_id uuid, p_token text, p_score integer, p_new_games integer default 0)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me public.players;
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  if p_score is null or p_score < 0 or p_score > 20000000 then raise exception 'bad_score'; end if;
  if me.last_submit is not null and me.last_submit > now() - interval '2 seconds' then raise exception 'slow_down'; end if;
  update public.players set
    games = games + greatest(0, least(coalesce(p_new_games, 0), 20)),
    last_submit = now(),
    best = greatest(best, p_score),
    best_at = case when p_score > best then now() else best_at end
  where id = me.id;
  return public.pop_board(p_id, p_token);
end $$;

-- The ladder: you, the top 50, and the 5 players either side of you. Equal scores share a rank.
create or replace function public.pop_board(p_id uuid, p_token text)
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare me public.players; out json;
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  with r as (
    select id, name, best,
           rank() over (order by best desc) as rank,
           row_number() over (order by best desc, best_at asc, created_at asc) as rn
    from public.players where not hidden and best > 0
  ), m as (select rn, rank from r where id = me.id)
  select json_build_object(
    'me', json_build_object('name', me.name, 'best', me.best, 'rank', (select rank from m), 'games', me.games),
    'total', (select count(*) from r),
    'top', coalesce((select json_agg(json_build_object('rank', rank, 'name', name, 'best', best, 'me', id = me.id) order by rn) from r where rn <= 50), '[]'::json),
    'near', coalesce((select json_agg(json_build_object('rank', r.rank, 'name', r.name, 'best', r.best, 'me', r.id = me.id) order by r.rn)
                      from r, m where m.rn > 50 and r.rn between m.rn - 5 and m.rn + 5), '[]'::json)
  ) into out;
  return out;
end $$;

revoke all on function public.pop_register(text) from public;
revoke all on function public.pop_rename(uuid, text, text) from public;
revoke all on function public.pop_score(uuid, text, integer, integer) from public;
revoke all on function public.pop_board(uuid, text) from public;
grant execute on function public.pop_register(text) to anon, authenticated;
grant execute on function public.pop_rename(uuid, text, text) to anon, authenticated;
grant execute on function public.pop_score(uuid, text, integer, integer) to anon, authenticated;
grant execute on function public.pop_board(uuid, text) to anon, authenticated;
-- Pop ladder update: every name on the ladder is unique.
-- If "Mark R" is taken, the next Mark R becomes "Mark R2", then "Mark R3" and so on.
-- Paste all of this into Supabase > SQL Editor > New query, then press Run. Safe to run again.

-- 1. Any names already doubled up get a number (the earliest keeps the plain name)
with d as (
  select id, name, row_number() over (partition by lower(name) order by created_at, id) as n
  from public.players
)
update public.players p set name = left(d.name, 17) || d.n
from d where p.id = d.id and d.n > 1;

-- 2. The database itself refuses two players with the same name (Mark R and mark r count as the same)
create unique index if not exists players_name_unique on public.players (lower(name));

-- 3. The first free version of a name: Mark R, Mark R2, Mark R3...
create or replace function public.pop_free_name(p_name text, p_me uuid default null)
returns text language plpgsql stable security definer set search_path = public as $$
declare cand text := p_name; n int := 1;
begin
  while exists (select 1 from public.players where lower(name) = lower(cand) and id is distinct from p_me) loop
    n := n + 1;
    cand := left(p_name, 20 - char_length(n::text)) || n;
  end loop;
  return cand;
end $$;
revoke all on function public.pop_free_name(text, uuid) from public, anon, authenticated;

-- 4. Joining: you get the name you asked for, or the next free number
create or replace function public.pop_register(p_name text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  nm  text := public.pop_clean_name(p_name);
  tok text := encode(extensions.gen_random_bytes(24), 'hex');
  pid uuid; got text; tries int := 0;
begin
  if char_length(nm) < 2 or char_length(nm) > 20 then raise exception 'bad_name'; end if;
  if (select count(*) from public.players where created_at > now() - interval '1 minute') >= 30 then
    raise exception 'busy';   -- flood guard: at most 30 new players a minute
  end if;
  loop
    got := public.pop_free_name(nm);
    begin
      insert into public.players (name, token_hash)
      values (got, encode(extensions.digest(tok, 'sha256'), 'hex'))
      returning id into pid;
      exit;
    exception when unique_violation then   -- two people grabbed the same name at the same moment
      tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  return json_build_object('id', pid, 'token', tok, 'name', got, 'asked', nm);
end $$;

-- 5. Changing your name works the same way
create or replace function public.pop_rename(p_id uuid, p_token text, p_name text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me public.players; nm text := public.pop_clean_name(p_name); got text; tries int := 0;
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  if char_length(nm) < 2 or char_length(nm) > 20 then raise exception 'bad_name'; end if;
  loop
    got := public.pop_free_name(nm, me.id);
    begin
      update public.players set name = got where id = me.id;
      exit;
    exception when unique_violation then
      tries := tries + 1; if tries > 5 then raise; end if;
    end;
  end loop;
  return public.pop_board(p_id, p_token);
end $$;

grant execute on function public.pop_register(text) to anon, authenticated;
grant execute on function public.pop_rename(uuid, text, text) to anon, authenticated;
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

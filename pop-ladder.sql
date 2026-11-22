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

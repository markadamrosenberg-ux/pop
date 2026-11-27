-- Pop ladder fix, 27 Nov. Paste ALL of this into Supabase > SQL Editor > New query, then press Run once.
--
-- What it does:
--  1. Merges people who are on the ladder twice into one entry:
--       Bek W (55,485)    goes into  Beki W (1,971,488)
--       Rayna R2 (62,735) goes into  Rayna R (112,367)
--     Nothing is lost: each keeps their higher best, games are added together, friendships move across,
--     and BOTH of their phones/apps keep working as the one player. Mark R is not touched.
--  2. The World ladder shows the top 100 (was 50) and you can add a friend by tapping their name.
--  3. The game can warn someone who's about to join under a name that's already playing.

-- ---------- 1a. let a second phone or app act as the same player ----------
create table if not exists public.player_aliases (
  old_id     uuid primary key,
  token_hash text not null,
  player_id  uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.player_aliases enable row level security;
revoke all on table public.player_aliases from anon, authenticated;

-- the player behind an id + secret key, or nothing (now also understands merged phones)
create or replace function public.pop_me(p_id uuid, p_token text)
returns public.players language sql stable security definer set search_path = public, extensions as $$
  select p.* from public.players p
  where (p.id = p_id and p.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex'))
     or p.id = (select a.player_id from public.player_aliases a
                where a.old_id = p_id and a.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex'))
  limit 1
$$;
revoke all on function public.pop_me(uuid, text) from public, anon, authenticated;

-- ---------- 1b. merge one entry into another (only runs from here, the game can't call it) ----------
create or replace function public.pop_merge(p_keep text, p_drop text)
returns text language plpgsql security definer set search_path = public as $$
declare k public.players; d public.players; moved int := 0; x uuid;
begin
  select * into k from public.players where lower(name) = lower(p_keep);
  select * into d from public.players where lower(name) = lower(p_drop);
  if k.id is null then return 'not found: ' || p_keep; end if;
  if d.id is null then return 'already done: ' || p_drop || ' is not on the ladder'; end if;
  if k.id = d.id then return 'same player'; end if;
  -- friendships move across (skipping any that would be with themselves or already exist)
  for x in select case when a = d.id then b else a end from public.friendships where a = d.id or b = d.id loop
    if x <> k.id then
      insert into public.friendships (a, b, via) values (least(k.id, x), greatest(k.id, x), 'merge') on conflict do nothing;
      moved := moved + 1;
    end if;
  end loop;
  -- keep the higher best and add the games together
  update public.players set
    best = greatest(k.best, d.best),
    best_at = case when d.best > k.best then d.best_at else k.best_at end,
    games = k.games + d.games
  where id = k.id;
  -- the dropped entry's phone keeps working, as the kept player
  insert into public.player_aliases (old_id, token_hash, player_id) values (d.id, d.token_hash, k.id)
    on conflict (old_id) do update set token_hash = excluded.token_hash, player_id = excluded.player_id;
  update public.player_aliases set player_id = k.id where player_id = d.id;
  delete from public.players where id = d.id;
  return 'merged ' || p_drop || ' into ' || p_keep || ' (' || moved || ' friendships moved)';
end $$;
revoke all on function public.pop_merge(text, text) from public, anon, authenticated;

-- ---------- 2. World ladder: top 100, and each row carries an id so you can tap to add ----------
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
    'top', coalesce((select json_agg(json_build_object('id', id, 'rank', rank, 'name', name, 'best', best, 'me', id = me.id) order by rn) from r where rn <= 100), '[]'::json),
    'near', coalesce((select json_agg(json_build_object('id', r.id, 'rank', r.rank, 'name', r.name, 'best', r.best, 'me', r.id = me.id) order by r.rn)
                      from r, m where m.rn > 100 and r.rn between m.rn - 5 and m.rn + 5), '[]'::json)
  ) into out;
  return out;
end $$;

-- the friends list now has to work from the merged player, not the phone's old id
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

-- add a friend straight from the World ladder
create or replace function public.pop_add_friend_id(p_id uuid, p_token text, p_friend uuid)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare me public.players; them public.players; lo uuid; hi uuid; cap int := 200;
begin
  select * into me from public.pop_me(p_id, p_token);
  if me.id is null then raise exception 'unknown_player'; end if;
  select * into them from public.players where id = p_friend and not hidden;
  if them.id is null then raise exception 'no_such_player'; end if;
  if them.id = me.id then raise exception 'thats_you'; end if;
  lo := least(me.id, them.id); hi := greatest(me.id, them.id);
  perform 1 from public.players where id in (lo, hi) order by id for update;
  if exists (select 1 from public.friendships where a = lo and b = hi) then return public.pop_friends(p_id, p_token); end if;
  if (select count(*) from public.friendships where a = me.id or b = me.id) >= cap then raise exception 'you_are_full'; end if;
  if (select count(*) from public.friendships where a = them.id or b = them.id) >= cap then raise exception 'they_are_full'; end if;
  insert into public.friendships (a, b, via) values (lo, hi, 'ladder') on conflict do nothing;
  return public.pop_friends(p_id, p_token);
end $$;

-- ---------- 3. is a name already playing? ----------
create or replace function public.pop_name_taken(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.players where lower(name) = lower(public.pop_clean_name(p_name)))
$$;

revoke all on function public.pop_board(uuid, text) from public;
revoke all on function public.pop_friends(uuid, text) from public;
revoke all on function public.pop_add_friend_id(uuid, text, uuid) from public;
revoke all on function public.pop_name_taken(text) from public;
grant execute on function public.pop_board(uuid, text) to anon, authenticated;
grant execute on function public.pop_friends(uuid, text) to anon, authenticated;
grant execute on function public.pop_add_friend_id(uuid, text, uuid) to anon, authenticated;
grant execute on function public.pop_name_taken(text) to anon, authenticated;

-- ---------- 4. do the two merges and show what happened ----------
select public.pop_merge('Beki W', 'Bek W') as bek, public.pop_merge('Rayna R', 'Rayna R2') as rayna;

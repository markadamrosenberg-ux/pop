-- Pop ladder fix (27 Nov): the World ladder shows the top 100, you can add a friend by tapping their name,
-- and the game can warn someone who's about to join under a name that's already playing.
-- Paste all of this into Supabase > SQL Editor > New query, then press Run. Safe to run again.
-- It deletes nothing.

-- 1. The ladder: you, the top 100, and the 5 players either side of you. Each row now carries the player's id,
--    so you can tap a name to add them as a friend. Equal scores share a rank.
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

-- 2. Add a friend straight from the World ladder (by tapping their name). Same rules as adding by code.
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

-- 3. Is this name already on the ladder? (So the game can say "If that's you on another phone, play there")
create or replace function public.pop_name_taken(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.players where lower(name) = lower(public.pop_clean_name(p_name)))
$$;

revoke all on function public.pop_board(uuid, text) from public;
revoke all on function public.pop_add_friend_id(uuid, text, uuid) from public;
revoke all on function public.pop_name_taken(text) from public;
grant execute on function public.pop_board(uuid, text) to anon, authenticated;
grant execute on function public.pop_add_friend_id(uuid, text, uuid) to anon, authenticated;
grant execute on function public.pop_name_taken(text) to anon, authenticated;

-- Pop ladder check (27 Nov): a list of every player, so we can spot people who are on the ladder twice.
-- This only LOOKS. It changes and deletes nothing.
-- Paste it into Supabase > SQL Editor > New query, press Run, then screenshot the results and send them to Claude.

select
  p.name,
  p.best,
  p.games,
  to_char(p.created_at at time zone 'Australia/Sydney', 'DD Mon HH24:MI') as joined,
  to_char(p.last_submit at time zone 'Australia/Sydney', 'DD Mon HH24:MI') as last_played,
  p.hidden,
  (select string_agg(q.name, ', ' order by q.name)
     from public.friendships f
     join public.players q on q.id = case when f.a = p.id then f.b else f.a end
    where f.a = p.id or f.b = p.id) as friends,
  left(p.id::text, 8) as id_start
from public.players p
order by p.best desc;

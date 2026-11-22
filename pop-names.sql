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

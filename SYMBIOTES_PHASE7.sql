-- SYMBIOTES PHASE 7: King Admins, glory rebuild, site text, profile video backdrop.
-- Run ONCE in Supabase > SQL Editor (after PHASE6). Safe to re-run. Then run SEED_KING_ADMINS.sql (kept OUT of GitHub).

-- ============ 1. Role helpers ============
create or replace function sym_is_king() returns boolean language sql stable security definer set search_path=public as $$
  select coalesce((select role::text = 'super_admin' and status::text = 'active' from profiles where id = auth.uid()), false) $$;
create or replace function sym_is_admin() returns boolean language sql stable security definer set search_path=public as $$
  select coalesce((select role::text in ('admin','super_admin') and status::text = 'active' from profiles where id = auth.uid()), false) $$;

-- ============ 2. Only the two founding King Admins can ever exist ============
create or replace function sym_guard_king() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.role::text = 'super_admin' and auth.uid() is not null then raise exception 'King Admins cannot be deleted'; end if;
    return old;
  end if;
  if (tg_op = 'INSERT' or old.role::text is distinct from new.role::text) and new.role::text = 'super_admin' and lower(new.username) not in ('symbiots','rin') then
    raise exception 'King Admin cannot be created';
  end if;
  if tg_op = 'UPDATE' and old.role::text is distinct from new.role::text and auth.uid() is not null and not sym_is_king() then
    raise exception 'Only a King Admin can change roles';
  end if;
  if tg_op = 'UPDATE' and old.role::text = 'super_admin' and auth.uid() is not null then
    if new.role::text <> 'super_admin' then raise exception 'King Admins cannot be demoted'; end if;
    if new.username is distinct from old.username then raise exception 'A King Admin username cannot be changed'; end if;
    if new.status::text <> 'active' and auth.uid() <> old.id then raise exception 'King Admins cannot be banned or suspended'; end if;
  end if;
  return new;
end $$;
drop trigger if exists sym_guard_king_t on profiles;
create trigger sym_guard_king_t before insert or update or delete on profiles for each row execute function sym_guard_king();

-- ============ 3. Glory rebuild (self-contained, no time window: admins and kings can upload any time) ============
create table if not exists gl_daily(
  member_id uuid not null references profiles on delete cascade,
  day date not null, total bigint not null check (total >= 0), gained bigint not null default 0,
  entered_by uuid references profiles on delete set null, updated_at timestamptz not null default now(),
  primary key(member_id, day));
create index if not exists gl_daily_day on gl_daily(day);
create table if not exists gl_last(
  member_id uuid not null references profiles on delete cascade,
  week_start date not null, last_glory bigint not null default 0 check (last_glory >= 0),
  entered_by uuid references profiles on delete set null, updated_at timestamptz not null default now(),
  primary key(member_id, week_start));
alter table gl_daily enable row level security; alter table gl_last enable row level security;
drop policy if exists gl_daily_sel on gl_daily; create policy gl_daily_sel on gl_daily for select to authenticated using (true);
drop policy if exists gl_last_sel on gl_last; create policy gl_last_sel on gl_last for select to authenticated using (true);

-- copy what was already saved in the old table (once; skipped if the old table looks different)
do $$ begin
  insert into gl_daily(member_id, day, total, gained)
  select member_id, day, coalesce(total,0), coalesce(gained,0) from glory_daily where member_id is not null and day is not null
  on conflict do nothing;
exception when others then raise notice 'old glory_daily not copied: %', sqlerrm; end $$;

create or replace function sym_week_start(d date) returns date language sql immutable as $$ select d - ((extract(isodow from d)::int) - 1) $$;
create or replace function sym_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- entries: [{"member_id":"...","total":12345}] = the member's total glory shown in the game on that day
create or replace function glory_submit_daily(p_day date, entries jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare e jsonb; m uuid; t bigint; prev bigint; n int := 0; d date := coalesce(p_day, sym_today());
begin
  if not sym_is_admin() then raise exception 'Admins only'; end if;
  if d > sym_today() then raise exception 'You cannot enter glory for a future day'; end if;
  for e in select * from jsonb_array_elements(coalesce(entries,'[]'::jsonb)) loop
    m := (e->>'member_id')::uuid; t := (e->>'total')::bigint;
    if t is null or t < 0 then continue; end if;
    select total into prev from gl_daily where member_id = m and day < d order by day desc limit 1;
    insert into gl_daily(member_id, day, total, gained, entered_by) values (m, d, t, case when prev is null then 0 else greatest(t - prev, 0) end, auth.uid())
    on conflict (member_id, day) do update set total = excluded.total, gained = excluded.gained, entered_by = excluded.entered_by, updated_at = now();
    update gl_daily g set gained = greatest(g.total - t, 0) where g.member_id = m and g.day = (select min(day) from gl_daily where member_id = m and day > d);
    n := n + 1;
  end loop;
  return jsonb_build_object('saved', n, 'day', d);
end $$;

-- entries: [{"member_id":"...","last":1200}] = "last glory" taken off that member's Mon-Sat sum
create or replace function glory_set_last(p_week date, entries jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare e jsonb; n int := 0; w date := sym_week_start(coalesce(p_week, sym_today()));
begin
  if not sym_is_admin() then raise exception 'Admins only'; end if;
  for e in select * from jsonb_array_elements(coalesce(entries,'[]'::jsonb)) loop
    insert into gl_last(member_id, week_start, last_glory, entered_by) values ((e->>'member_id')::uuid, w, greatest(coalesce((e->>'last')::bigint,0),0), auth.uid())
    on conflict (member_id, week_start) do update set last_glory = excluded.last_glory, entered_by = excluded.entered_by, updated_at = now();
    n := n + 1;
  end loop;
  return jsonb_build_object('saved', n, 'week', w);
end $$;

-- one row per active member for a week: Mon-Sat sum of daily glory minus "last glory"
create or replace function glory_week(p_week date default null) returns table(member_id uuid, daily_sum bigint, last_glory bigint, weekly bigint) language sql stable security definer set search_path=public as $$
  with w as (select sym_week_start(coalesce(p_week, sym_today())) as s),
  x as (select p.id as mid,
      coalesce((select sum(g.gained) from gl_daily g, w where g.member_id = p.id and g.day >= w.s and g.day <= w.s + 5), 0)::bigint as ds,
      coalesce((select l.last_glory from gl_last l, w where l.member_id = p.id and l.week_start = w.s), 0)::bigint as lg
    from profiles p where p.status::text = 'active')
  select mid, ds, lg, greatest(ds - lg, 0)::bigint from x $$;
grant execute on function glory_week(date) to authenticated;

create or replace view v_lb_daily as
  select p.id as member_id, p.username, p.display_name, p.avatar_url, g.gained::bigint as glory, rank() over (order by g.gained desc)::int as rnk
  from gl_daily g join profiles p on p.id = g.member_id
  where p.status::text = 'active' and g.day = (select max(day) from gl_daily);
create or replace view v_lb_weekly as
  select p.id as member_id, p.username, p.display_name, p.avatar_url, w.weekly as glory, rank() over (order by w.weekly desc)::int as rnk
  from glory_week() w join profiles p on p.id = w.member_id where w.weekly > 0;
create or replace view v_lb_monthly as
  select p.id as member_id, p.username, p.display_name, p.avatar_url, s.glory, rank() over (order by s.glory desc)::int as rnk
  from (select member_id, sum(gained)::bigint as glory from gl_daily where day >= date_trunc('month', sym_today())::date group by member_id) s
  join profiles p on p.id = s.member_id where p.status::text = 'active' and s.glory > 0;
create or replace view v_lb_lifetime as
  select p.id as member_id, p.username, p.display_name, p.avatar_url, s.glory, rank() over (order by s.glory desc)::int as rnk
  from (select distinct on (member_id) member_id, total::bigint as glory from gl_daily order by member_id, day desc) s
  join profiles p on p.id = s.member_id where p.status::text = 'active';
grant select on v_lb_daily, v_lb_weekly, v_lb_monthly, v_lb_lifetime to authenticated;

-- quests read the new glory tables
create or replace function style_metric(p_member uuid, p_metric text) returns int language plpgsql stable security definer set search_path=public as $$
declare v bigint := 0; d date; today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if p_metric = 'photo' then select case when coalesce(avatar_url,'') <> '' then 1 else 0 end into v from profiles where id = p_member;
  elsif p_metric = 'bio' then select case when char_length(btrim(coalesce(bio,''))) >= 10 then 1 else 0 end into v from profiles where id = p_member;
  elsif p_metric = 'game_id' then select case when coalesce(ff_uid::text,'') not in ('','0') and coalesce(ff_ign,'') <> '' then 1 else 0 end into v from profiles where id = p_member;
  elsif p_metric = 'visit_days' then select count(*) into v from site_visits where member_id = p_member;
  elsif p_metric = 'streak' then
    d := today; if not exists(select 1 from site_visits where member_id = p_member and day = d) then d := d - 1; end if;
    while exists(select 1 from site_visits where member_id = p_member and day = d) loop v := v + 1; d := d - 1; end loop;
  elsif p_metric = 'weekly_glory' then select coalesce(max(weekly),0) into v from glory_week() where member_id = p_member;
  elsif p_metric = 'best_week' then
    select coalesce(max(z.x),0) into v from (select greatest(coalesce((select sum(g.gained) from gl_daily g where g.member_id = p_member and g.day >= ws.s and g.day <= ws.s + 5),0)
      - coalesce((select l.last_glory from gl_last l where l.member_id = p_member and l.week_start = ws.s),0), 0) as x
      from (select distinct sym_week_start(day) as s from gl_daily where member_id = p_member) ws) z;
  elsif p_metric = 'lifetime_glory' then select coalesce(max(glory),0) into v from v_lb_lifetime where member_id = p_member;
  elsif p_metric = 'badges' then select count(*) into v from member_badges where member_id = p_member;
  elsif p_metric = 'polls' then select count(*) into v from poll_votes where user_id = p_member;
  elsif p_metric = 'messages' then select count(*) into v from messages where sender_id = p_member and deleted_at is null;
  end if;
  return least(coalesce(v,0), 2000000000)::int;
end $$;

-- ============ 4. Profile video backdrop ============
alter table member_style add column if not exists bg_media text;
alter table member_style add column if not exists bg_poster text;
alter table member_style add column if not exists bg_kind text;

-- picture backdrops removed: their quests now give other styles, wearers fall back to Midnight
update style_tasks set reward_code = case title when 'Warm up' then 'cd_emerald' when 'Garden party' then 'cd_rose' when 'Loud and proud' then 'nm_amethyst' when 'Rooftop regular' then 'au_stars' when 'Stargazer' then 'nm_aurora' else reward_code end
  where reward_code in ('bd_room1','bd_room2','bd_room3','bd_room4','bd_room5');
update member_style set backdrop = 'bd_night' where backdrop in ('bd_room1','bd_room2','bd_room3','bd_room4','bd_room5');
delete from style_items where code in ('bd_room1','bd_room2','bd_room3','bd_room4','bd_room5');

insert into style_items(code, slot, name, rarity, description, is_free) values
('bd_myvideo','backdrop','My Video Backdrop','legendary','Upload your own looping video as your profile background.',false)
on conflict (code) do update set name = excluded.name, rarity = excluded.rarity, description = excluded.description where style_items.custom = false;
insert into style_tasks(title, description, kind, metric, target, reward_code, sort)
select 'Cinema profile','Reach 20,000 lifetime glory to upload your own video backdrop.','auto','lifetime_glory',20000,'bd_myvideo',245
where not exists (select 1 from style_tasks where title = 'Cinema profile');

-- King Admins own every style, free
create or replace function style_owns(p_member uuid, p_code text) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from profiles where id = p_member and role::text = 'super_admin')
      or exists(select 1 from style_items i where i.code = p_code and i.active and i.is_free)
      or exists(select 1 from style_unlocks u join style_items i on i.code = u.item_code where u.member_id = p_member and u.item_code = p_code and i.active) $$;

create or replace function style_equip(p_patch jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); k text; v text; it style_items; pre text := '%/storage/v1/object/public/site-media/profile-bg/' || auth.uid()::text || '/%';
begin
  if uid is null or not is_active() then raise exception 'not allowed'; end if;
  insert into member_style(member_id) values(uid) on conflict do nothing;
  for k, v in select key, value from jsonb_each_text(p_patch) loop
    if k = 'status' then
      update member_style set status = left(btrim(regexp_replace(coalesce(v,''), '[<>[:cntrl:]]', '', 'g')), 60), updated_at = now() where member_id = uid;
    elsif k in ('bg_media','bg_poster') then
      if coalesce(v,'') <> '' and v not like pre then raise exception 'That video is not yours'; end if;
      if coalesce(v,'') <> '' and not style_owns(uid, 'bd_myvideo') then raise exception 'Video backdrops are locked for you'; end if;
      execute format('update member_style set %I = nullif($1,%L), updated_at = now() where member_id = $2', k, '') using v, uid;
    elsif k = 'bg_kind' then
      update member_style set bg_kind = case when v in ('video','image') then v else null end, updated_at = now() where member_id = uid;
    elsif k in ('frame','namefx','backdrop','aura','card','title') then
      select * into it from style_items where code = v and active;
      if not found or it.slot <> k then raise exception 'Unknown item'; end if;
      if not style_owns(uid, v) then raise exception 'You have not unlocked "%" yet', it.name; end if;
      execute format('update member_style set %I = $1, updated_at = now() where member_id = $2', k) using v, uid;
    end if;
  end loop;
  return (select to_jsonb(m) - 'member_id' - 'updated_at' from member_style m where m.member_id = uid);
end $$;

-- members upload only into their own profile-bg folder of the public site-media bucket
do $$ begin
  drop policy if exists sym_profile_bg_ins on storage.objects;
  create policy sym_profile_bg_ins on storage.objects for insert to authenticated
    with check (bucket_id = 'site-media' and (storage.foldername(name))[1] = 'profile-bg' and (storage.foldername(name))[2] = auth.uid()::text);
  drop policy if exists sym_profile_bg_del on storage.objects;
  create policy sym_profile_bg_del on storage.objects for delete to authenticated
    using (bucket_id = 'site-media' and (storage.foldername(name))[1] = 'profile-bg' and (storage.foldername(name))[2] = auth.uid()::text);
exception when others then raise notice 'storage policies skipped (add in Storage > Policies): %', sqlerrm; end $$;

create or replace function style_players() returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not is_active() then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(s.x order by lower(coalesce(s.x->>'display_name', s.x->>'username'))) from (
    select jsonb_build_object(
      'id',p.id,'username',p.username,'display_name',p.display_name,'avatar_url',p.avatar_url,'role',p.role::text,'ff_ign',p.ff_ign,'ff_rank',p.ff_rank,'player_level',p.player_level,'bio',p.bio,
      'glory',(select coalesce(l.glory,0) from v_lb_lifetime l where l.member_id = p.id),
      'rank',(select l.rnk from v_lb_lifetime l where l.member_id = p.id),
      'badges',(select count(*) from member_badges b where b.member_id = p.id),
      'style',coalesce((select to_jsonb(m) - 'member_id' - 'updated_at' from member_style m where m.member_id = p.id),'{}'::jsonb),
      'owned',coalesce((select jsonb_agg(u.item_code) from style_unlocks u where u.member_id = p.id),'[]'::jsonb)) as x
    from profiles p where p.status::text = 'active') s),'[]'::jsonb);
end $$;

-- ============ 5. Permissions: gifting + custom items = King Admins; quests, glory, site text = admins ============
drop policy if exists si_adm on style_items; create policy si_adm on style_items for all to authenticated using (sym_is_king()) with check (sym_is_king());
drop policy if exists st_adm on style_tasks; create policy st_adm on style_tasks for all to authenticated using (sym_is_admin()) with check (sym_is_admin());

create or replace function style_gift(p_member uuid, p_item text, p_note text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare it style_items;
begin
  if not sym_is_king() then raise exception 'Only King Admins can gift'; end if;
  select * into it from style_items where code = p_item and active; if not found then raise exception 'Item not found'; end if;
  if style_owns(p_member, p_item) then raise exception 'They already have that'; end if;
  insert into style_unlocks(member_id,item_code,source,granted_by,note) values(p_member,p_item,'gift',auth.uid(),left(btrim(coalesce(p_note,'')),200));
  insert into notifications(user_id,type,title,body,link) values(p_member,'reward','A gift from the King 🎁', it.name||coalesce(' - '||nullif(btrim(p_note),''),''),'/style');
  return jsonb_build_object('ok',true);
end $$;

create or replace function style_gift_all(p_item text, p_note text default null) returns int language plpgsql security definer set search_path=public as $$
declare it style_items; n int;
begin
  if not sym_is_king() then raise exception 'Only King Admins can gift'; end if;
  select * into it from style_items where code = p_item and active; if not found then raise exception 'Item not found'; end if;
  with ins as (
    insert into style_unlocks(member_id,item_code,source,granted_by,note)
    select p.id,p_item,'gift',auth.uid(),left(btrim(coalesce(p_note,'')),200) from profiles p where p.status::text = 'active' and not style_owns(p.id,p_item)
    on conflict do nothing returning member_id)
  insert into notifications(user_id,type,title,body,link) select member_id,'reward','A gift for everyone 🎁', it.name||coalesce(' - '||nullif(btrim(p_note),''),''),'/style' from ins;
  get diagnostics n = row_count; return n;
end $$;

-- every premium style to one player at once
create or replace function style_gift_bundle(p_member uuid, p_note text default null) returns int language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if not sym_is_king() then raise exception 'Only King Admins can gift'; end if;
  with ins as (
    insert into style_unlocks(member_id,item_code,source,granted_by,note)
    select p_member, i.code, 'gift', auth.uid(), left(btrim(coalesce(p_note,'')),200) from style_items i where i.active and not i.is_free
    on conflict do nothing returning item_code)
  select count(*) into n from ins;
  insert into notifications(user_id,type,title,body,link) values(p_member,'reward','The King unlocked everything for you 👑', n||' styles added. Open Style Studio.','/style');
  return n;
end $$;

create or replace function style_revoke(p_member uuid, p_item text) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not sym_is_king() then raise exception 'Only King Admins can take styles back'; end if;
  if not exists(select 1 from style_items where code = p_item) then raise exception 'Item not found'; end if;
  delete from style_unlocks where member_id = p_member and item_code = p_item;
  update member_style set
    frame = case when frame = p_item then 'fr_plain' else frame end, namefx = case when namefx = p_item then 'nm_plain' else namefx end,
    backdrop = case when backdrop = p_item then 'bd_night' else backdrop end, aura = case when aura = p_item then 'au_none' else aura end,
    card = case when card = p_item then 'cd_glass' else card end, title = case when title = p_item then 'tt_none' else title end, updated_at = now()
  where member_id = p_member;
  return jsonb_build_object('ok',true);
end $$;

create or replace function style_item_delete(p_code text) returns jsonb language plpgsql security definer set search_path=public as $$
declare it style_items;
begin
  if not sym_is_king() then raise exception 'Only King Admins can delete styles'; end if;
  select * into it from style_items where code = p_code; if not found then raise exception 'Item not found'; end if;
  if not it.custom then raise exception 'Built-in items cannot be deleted'; end if;
  update member_style set
    frame = case when frame = p_code then 'fr_plain' else frame end, namefx = case when namefx = p_code then 'nm_plain' else namefx end,
    backdrop = case when backdrop = p_code then 'bd_night' else backdrop end, aura = case when aura = p_code then 'au_none' else aura end,
    card = case when card = p_code then 'cd_glass' else card end, title = case when title = p_code then 'tt_none' else title end, updated_at = now();
  delete from style_items where code = p_code;
  return jsonb_build_object('ok',true);
end $$;

create or replace function style_review(p_id uuid, p_approve boolean, p_reason text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare s style_submissions; t style_tasks; it style_items;
begin
  if not sym_is_admin() then raise exception 'Admins only'; end if;
  select * into s from style_submissions where id = p_id for update; if not found then raise exception 'Not found'; end if;
  if s.status <> 'pending' then raise exception 'Already reviewed'; end if;
  select * into t from style_tasks where id = s.task_id; select * into it from style_items where code = t.reward_code;
  if p_approve then
    update style_submissions set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now() where id = s.id;
    insert into style_unlocks(member_id,item_code,source,task_id,granted_by) values(s.member_id,t.reward_code,'task',t.id,auth.uid()) on conflict do nothing;
    insert into notifications(user_id,type,title,body,link) values(s.member_id,'reward','Quest approved 🏆','"'||t.title||'" - you unlocked '||it.name||'.','/style');
  else
    if char_length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'Please give a short reason'; end if;
    update style_submissions set status = 'rejected', reason = btrim(p_reason), reviewed_by = auth.uid(), reviewed_at = now() where id = s.id;
    insert into notifications(user_id,type,title,body,link) values(s.member_id,'reward','Quest not approved','"'||t.title||'": '||btrim(p_reason),'/quests');
  end if;
  return jsonb_build_object('ok',true);
end $$;

-- ============ 6. Site text + public reads for the visitors page, writes for admins ============
alter table site_settings enable row level security;
drop policy if exists sym_ss_public_read on site_settings;
create policy sym_ss_public_read on site_settings for select to anon, authenticated using (key in ('site_text','intro','guild_links'));
drop policy if exists sym_ss_admin_write on site_settings;
create policy sym_ss_admin_write on site_settings for all to authenticated using (sym_is_admin()) with check (sym_is_admin());

-- SYMBIOTES PHASE 6 - profile customisation (frames, golden profile, video backdrops, auras, titles), quests and admin gifts.
-- Run once in Supabase > SQL Editor AFTER SYMBIOTES_PHASE4.sql and SYMBIOTES_PHASE5_INTRO.sql. Safe to re-run any number of times.
-- Nothing is dropped.
-- Needs the helper functions from the earlier files: is_admin(), is_active(), audit(), and the tables profiles, site_visits, glory_totals, glory_weeks, member_badges, poll_votes, messages, notifications, and the view lb_lifetime.

-- ============ 1. Tables ============
create table if not exists style_items(
  code text primary key,
  slot text not null check (slot in ('frame','namefx','backdrop','aura','card','title')),
  name text not null check (char_length(name) between 2 and 40),
  rarity text not null default 'common' check (rarity in ('common','rare','epic','legendary')),
  description text not null default '',
  is_free boolean not null default false,
  media text, poster text, kind text check (kind in ('video','image')),
  custom boolean not null default false,
  active boolean not null default true,
  created_by uuid references profiles on delete set null,
  created_at timestamptz not null default now());

create table if not exists style_unlocks(
  member_id uuid not null references profiles on delete cascade,
  item_code text not null references style_items(code) on delete cascade,
  source text not null default 'task' check (source in ('task','gift')),
  task_id uuid, granted_by uuid references profiles on delete set null, note text,
  seen boolean not null default false, created_at timestamptz not null default now(),
  primary key(member_id, item_code));
create index if not exists style_unlocks_member on style_unlocks(member_id);

create table if not exists member_style(
  member_id uuid primary key references profiles on delete cascade,
  frame text not null default 'fr_plain', namefx text not null default 'nm_plain', backdrop text not null default 'bd_night',
  aura text not null default 'au_none', card text not null default 'cd_glass', title text not null default 'tt_none',
  status text not null default '' check (char_length(status) <= 60),
  updated_at timestamptz not null default now());

create table if not exists style_tasks(
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 80),
  description text not null default '',
  kind text not null default 'auto' check (kind in ('auto','manual')),
  metric text, target int not null default 1 check (target >= 1),
  reward_code text not null references style_items(code) on delete cascade,
  sort int not null default 100, active boolean not null default true,
  created_at timestamptz not null default now(),
  check (kind = 'manual' or metric is not null));

create table if not exists style_submissions(
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references style_tasks on delete cascade,
  member_id uuid not null references profiles on delete cascade,
  note text not null default '' check (char_length(note) <= 400),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reason text, reviewed_by uuid references profiles on delete set null, reviewed_at timestamptz,
  created_at timestamptz not null default now());
create unique index if not exists style_sub_one_pending on style_submissions(task_id, member_id) where status = 'pending';

-- ============ 2. Row level security: everyone signed in can SEE styles (that is the point), only the functions below can change them ============
alter table style_items enable row level security;
alter table style_unlocks enable row level security;
alter table member_style enable row level security;
alter table style_tasks enable row level security;
alter table style_submissions enable row level security;
drop policy if exists si_sel on style_items;  create policy si_sel on style_items for select to authenticated using (true);
drop policy if exists si_adm on style_items;  create policy si_adm on style_items for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists su_sel on style_unlocks; create policy su_sel on style_unlocks for select to authenticated using (true);
drop policy if exists ms_sel on member_style;  create policy ms_sel on member_style for select to authenticated using (true);
drop policy if exists st_sel on style_tasks;   create policy st_sel on style_tasks for select to authenticated using (true);
drop policy if exists st_adm on style_tasks;   create policy st_adm on style_tasks for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists ss_sel on style_submissions; create policy ss_sel on style_submissions for select to authenticated using (member_id = auth.uid() or public.is_admin());

do $$ begin alter publication supabase_realtime add table member_style;
exception when others then raise notice 'realtime for member_style skipped (already on, or add it in Database > Replication): %', sqlerrm; end $$;

-- ============ 3. Built-in catalogue (same codes as styleCatalog.ts) ============
insert into style_items(code, slot, name, rarity, description, is_free) values
('fr_plain','frame','Classic Ring','common','A clean violet ring.',true),
('fr_bronze','frame','Bronze Ring','common','Warm bronze, your first shine.',false),
('fr_silver','frame','Silver Ring','common','Cool polished silver.',false),
('fr_amethyst','frame','Amethyst Ring','rare','Deep violet crystal glow.',false),
('fr_gold','frame','Golden Frame','epic','A slowly shimmering gold ring.',false),
('fr_diamond','frame','Diamond Frame','epic','Ice-white diamond sparkle.',false),
('fr_ember','frame','Ember Ring','epic','A ring of living flame.',false),
('fr_aurora','frame','Aurora Ring','legendary','Northern lights circling your photo.',false),
('fr_royal','frame','Royal Crown','legendary','Gold ring with a crown on top.',false),
('nm_plain','namefx','Plain Name','common','Simple white.',true),
('nm_silver','namefx','Silver Script','common','Soft silver gradient.',false),
('nm_amethyst','namefx','Amethyst Name','rare','Violet to rose gradient.',false),
('nm_frost','namefx','Frost Name','rare','Icy white to sky blue.',false),
('nm_gold','namefx','Golden Name','epic','Shimmering liquid gold.',false),
('nm_ember','namefx','Ember Name','epic','Fire orange to red.',false),
('nm_aurora','namefx','Aurora Name','legendary','Colours that slowly drift.',false),
('nm_royal','namefx','Royal Glow','legendary','Gold lettering with a glow.',false),
('bd_night','backdrop','Midnight','common','Deep violet night.',true),
('bd_room1','backdrop','Guild Lounge','common','The warm wooden lounge.',false),
('bd_room2','backdrop','Sakura Garden','rare','Cherry blossoms by the pond.',false),
('bd_room3','backdrop','Gamer Loft','rare','Neon loft with a trophy wall.',false),
('bd_room4','backdrop','Rooftop Dusk','rare','Sunset over the city lights.',false),
('bd_room5','backdrop','Observatory','epic','A dome of galaxies.',false),
('bd_nebula','backdrop','Nebula','rare','Soft purple and rose clouds.',false),
('bd_ember','backdrop','Cinder','rare','Smouldering red and orange.',false),
('bd_gold','backdrop','Gilded','epic','Rich flowing gold.',false),
('bd_aurora','backdrop','Northern Lights','epic','Slow moving green and violet light.',false),
('bd_stars','backdrop','Starfall','legendary','A twinkling star field.',false),
('au_none','aura','No Aura','common','Clean and quiet.',true),
('au_violet','aura','Violet Haze','rare','A gentle pulsing glow.',false),
('au_snow','aura','Soft Snow','rare','Snowflakes drift down.',false),
('au_sparkle','aura','Gold Sparkle','epic','Golden sparks rise and fade.',false),
('au_embers','aura','Rising Embers','epic','Warm embers float upward.',false),
('au_stars','aura','Starlight','legendary','Little stars twinkle all around.',false),
('cd_glass','card','Glass','common','The standard frosted glass.',true),
('cd_obsidian','card','Obsidian','rare','Black stone with a violet edge.',false),
('cd_amethyst','card','Amethyst','rare','Violet tinted card.',false),
('cd_emerald','card','Emerald','rare','Deep green card.',false),
('cd_rose','card','Rose','rare','Rose pink card.',false),
('cd_ice','card','Glacier','rare','Cold blue card.',false),
('cd_gold','card','Golden Profile','legendary','The whole profile in gold: border, glow and accents.',false),
('tt_none','title','No Title','common','Show no title.',true),
('tt_rookie','title','Rookie','common','Everyone starts somewhere.',false),
('tt_regular','title','Regular','common','Always around.',false),
('tt_veteran','title','Veteran','rare','Seen it all.',false),
('tt_strategist','title','Strategist','rare','Plans win games.',false),
('tt_recruiter','title','Recruiter','rare','Brought new blood.',false),
('tt_champion','title','Champion','epic','Tournament level.',false),
('tt_mvp','title','Weekly MVP','epic','Best of the week.',false),
('tt_legend','title','Legend','legendary','Talked about for years.',false),
('tt_vip','title','VIP','legendary','Given by the admins.',false),
('tt_founder','title','Founder','legendary','Only for the founders.',false)
on conflict (code) do update set slot = excluded.slot, name = excluded.name, rarity = excluded.rarity, description = excluded.description, is_free = excluded.is_free
  where style_items.custom = false;

-- ============ 4. Helpers ============
create or replace function style_owns(p_member uuid, p_code text) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from style_items i where i.code = p_code and i.active and i.is_free)
      or exists(select 1 from style_unlocks u join style_items i on i.code = u.item_code where u.member_id = p_member and u.item_code = p_code and i.active) $$;

-- how far a member is on one measurable quest
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
  elsif p_metric = 'weekly_glory' then select coalesce(weekly,0) into v from glory_totals where member_id = p_member;
  elsif p_metric = 'best_week' then
    select greatest(coalesce((select max(total) from glory_weeks where member_id = p_member),0), coalesce((select weekly from glory_totals where member_id = p_member),0)) into v;
  elsif p_metric = 'lifetime_glory' then select coalesce(glory,0) into v from lb_lifetime where member_id = p_member;
  elsif p_metric = 'badges' then select count(*) into v from member_badges where member_id = p_member;
  elsif p_metric = 'polls' then select count(*) into v from poll_votes where user_id = p_member;
  elsif p_metric = 'messages' then select count(*) into v from messages where sender_id = p_member and deleted_at is null;
  end if;
  return least(coalesce(v,0), 2000000000)::int;
end $$;

-- ============ 5. Member functions ============
create or replace function style_overview() returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid();
begin
  if uid is null or not is_active() then raise exception 'not allowed'; end if;
  insert into member_style(member_id) values(uid) on conflict do nothing;
  return jsonb_build_object(
    'equipped', (select to_jsonb(m) - 'member_id' - 'updated_at' from member_style m where m.member_id = uid),
    'owned', coalesce((select jsonb_agg(jsonb_build_object('code',u.item_code,'source',u.source,'note',u.note,'seen',u.seen,'at',u.created_at) order by u.created_at desc) from style_unlocks u where u.member_id = uid),'[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object(
        'id',t.id,'title',t.title,'description',t.description,'kind',t.kind,'metric',t.metric,'target',t.target,'reward',t.reward_code,
        'progress', case when t.kind = 'auto' then least(style_metric(uid,t.metric), t.target) else 0 end,
        'owned', style_owns(uid, t.reward_code),
        'pending', exists(select 1 from style_submissions s where s.task_id = t.id and s.member_id = uid and s.status = 'pending'),
        'rejected', (select case when s.status = 'rejected' then coalesce(s.reason,'Not approved') end from style_submissions s where s.task_id = t.id and s.member_id = uid order by s.created_at desc limit 1)
      ) order by t.sort, t.created_at) from style_tasks t where t.active and exists(select 1 from style_items i where i.code = t.reward_code and i.active)),'[]'::jsonb));
end $$;

create or replace function style_claim(p_task uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); t style_tasks; cur int; it style_items;
begin
  if uid is null or not is_active() then raise exception 'not allowed'; end if;
  perform pg_advisory_xact_lock(hashtext('style:'||uid::text));
  select * into t from style_tasks where id = p_task and active; if not found then raise exception 'That quest does not exist'; end if;
  if t.kind <> 'auto' then raise exception 'This quest is checked by the admins'; end if;
  if style_owns(uid, t.reward_code) then raise exception 'You already own that reward'; end if;
  cur := style_metric(uid, t.metric);
  if cur < t.target then raise exception 'Not finished yet (% of %)', cur, t.target; end if;
  select * into it from style_items where code = t.reward_code and active; if not found then raise exception 'Reward is not available'; end if;
  insert into style_unlocks(member_id,item_code,source,task_id) values(uid,t.reward_code,'task',t.id) on conflict do nothing;
  insert into notifications(user_id,type,title,body,link) values(uid,'reward','Quest complete 🏆','You unlocked '||it.name||'. Equip it in Style Studio.','/style');
  return jsonb_build_object('ok',true,'item',it.code,'name',it.name);
end $$;

create or replace function style_submit(p_task uuid, p_note text default '') returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); t style_tasks; n text := left(btrim(coalesce(p_note,'')),400);
begin
  if uid is null or not is_active() then raise exception 'not allowed'; end if;
  select * into t from style_tasks where id = p_task and active; if not found then raise exception 'That quest does not exist'; end if;
  if t.kind <> 'manual' then raise exception 'This quest completes by itself'; end if;
  if style_owns(uid, t.reward_code) then raise exception 'You already own that reward'; end if;
  if char_length(n) < 3 then raise exception 'Please add a short note for the admins'; end if;
  if exists(select 1 from style_submissions where task_id = t.id and member_id = uid and status = 'pending') then raise exception 'Already sent. The admins will check it soon'; end if;
  insert into style_submissions(task_id,member_id,note) values(t.id,uid,n);
  insert into notifications(user_id,type,title,body,link) select id,'reward','Quest to review',t.title||' - '||(select coalesce(display_name,username) from profiles where id = uid),'/admin/style' from profiles where role::text in ('admin','super_admin') and status = 'active';
  return jsonb_build_object('ok',true);
end $$;

create or replace function style_equip(p_patch jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); k text; v text; it style_items;
begin
  if uid is null or not is_active() then raise exception 'not allowed'; end if;
  insert into member_style(member_id) values(uid) on conflict do nothing;
  for k, v in select key, value from jsonb_each_text(p_patch) loop
    if k = 'status' then
      update member_style set status = left(btrim(regexp_replace(coalesce(v,''), '[<>[:cntrl:]]', '', 'g')), 60), updated_at = now() where member_id = uid;
    elsif k in ('frame','namefx','backdrop','aura','card','title') then
      select * into it from style_items where code = v and active;
      if not found or it.slot <> k then raise exception 'Unknown item'; end if;
      if not style_owns(uid, v) then raise exception 'You have not unlocked "%" yet', it.name; end if;
      execute format('update member_style set %I = $1, updated_at = now() where member_id = $2', k) using v, uid;
    end if;
  end loop;
  return (select to_jsonb(m) - 'member_id' - 'updated_at' from member_style m where m.member_id = uid);
end $$;

create or replace function style_mark_seen() returns void language sql security definer set search_path=public as $$
  update style_unlocks set seen = true where member_id = auth.uid() and not seen $$;

-- everyone's look + collection for the Players page
create or replace function style_players() returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not is_active() then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(s.x order by lower(coalesce(s.x->>'display_name', s.x->>'username'))) from (
    select jsonb_build_object(
      'id',p.id,'username',p.username,'display_name',p.display_name,'avatar_url',p.avatar_url,'role',p.role::text,'ff_ign',p.ff_ign,'ff_rank',p.ff_rank,'player_level',p.player_level,'bio',p.bio,
      'glory',(select coalesce(l.glory,0) from lb_lifetime l where l.member_id = p.id),
      'rank',(select l.rnk from lb_lifetime l where l.member_id = p.id),
      'badges',(select count(*) from member_badges b where b.member_id = p.id),
      'style',coalesce((select to_jsonb(m) - 'member_id' - 'updated_at' from member_style m where m.member_id = p.id),'{}'::jsonb),
      'owned',coalesce((select jsonb_agg(u.item_code) from style_unlocks u where u.member_id = p.id),'[]'::jsonb)) as x
    from profiles p where p.status = 'active') s),'[]'::jsonb);
end $$;

-- ============ 6. Admin functions ============
create or replace function style_review(p_id uuid, p_approve boolean, p_reason text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare s style_submissions; t style_tasks; it style_items;
begin
  if auth.uid() is null or not is_admin() then raise exception 'Admins only'; end if;
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
  perform audit('style_review', s.id::text, jsonb_build_object('approve',p_approve));
  return jsonb_build_object('ok',true);
end $$;

create or replace function style_gift(p_member uuid, p_item text, p_note text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare it style_items;
begin
  if auth.uid() is null or not is_admin() then raise exception 'Admins only'; end if;
  select * into it from style_items where code = p_item and active; if not found then raise exception 'Item not found'; end if;
  if style_owns(p_member, p_item) then raise exception 'They already have that'; end if;
  insert into style_unlocks(member_id,item_code,source,granted_by,note) values(p_member,p_item,'gift',auth.uid(),left(btrim(coalesce(p_note,'')),200));
  insert into notifications(user_id,type,title,body,link) values(p_member,'reward','A gift from the admins 🎁', it.name||coalesce(' - '||nullif(btrim(p_note),''),''),'/style');
  perform audit('style_gift', p_member::text, jsonb_build_object('item',p_item));
  return jsonb_build_object('ok',true);
end $$;

create or replace function style_gift_all(p_item text, p_note text default null) returns int language plpgsql security definer set search_path=public as $$
declare it style_items; n int;
begin
  if auth.uid() is null or not is_admin() then raise exception 'Admins only'; end if;
  select * into it from style_items where code = p_item and active; if not found then raise exception 'Item not found'; end if;
  with ins as (
    insert into style_unlocks(member_id,item_code,source,granted_by,note)
    select p.id,p_item,'gift',auth.uid(),left(btrim(coalesce(p_note,'')),200) from profiles p where p.status = 'active' and not style_owns(p.id,p_item)
    on conflict do nothing returning member_id)
  insert into notifications(user_id,type,title,body,link) select member_id,'reward','A gift for everyone 🎁', it.name||coalesce(' - '||nullif(btrim(p_note),''),''),'/style' from ins;
  get diagnostics n = row_count;
  perform audit('style_gift_all', p_item, jsonb_build_object('count',n));
  return n;
end $$;

create or replace function style_revoke(p_member uuid, p_item text) returns jsonb language plpgsql security definer set search_path=public as $$
declare it style_items;
begin
  if auth.uid() is null or not is_admin() then raise exception 'Admins only'; end if;
  select * into it from style_items where code = p_item; if not found then raise exception 'Item not found'; end if;
  delete from style_unlocks where member_id = p_member and item_code = p_item;
  update member_style set
    frame = case when frame = p_item then 'fr_plain' else frame end, namefx = case when namefx = p_item then 'nm_plain' else namefx end,
    backdrop = case when backdrop = p_item then 'bd_night' else backdrop end, aura = case when aura = p_item then 'au_none' else aura end,
    card = case when card = p_item then 'cd_glass' else card end, title = case when title = p_item then 'tt_none' else title end, updated_at = now()
  where member_id = p_member;
  perform audit('style_revoke', p_member::text, jsonb_build_object('item',p_item));
  return jsonb_build_object('ok',true);
end $$;

create or replace function style_item_delete(p_code text) returns jsonb language plpgsql security definer set search_path=public as $$
declare it style_items;
begin
  if auth.uid() is null or not is_admin() then raise exception 'Admins only'; end if;
  select * into it from style_items where code = p_code; if not found then raise exception 'Item not found'; end if;
  if not it.custom then raise exception 'Built-in items cannot be deleted'; end if;
  update member_style set
    frame = case when frame = p_code then 'fr_plain' else frame end, namefx = case when namefx = p_code then 'nm_plain' else namefx end,
    backdrop = case when backdrop = p_code then 'bd_night' else backdrop end, aura = case when aura = p_code then 'au_none' else aura end,
    card = case when card = p_code then 'cd_glass' else card end, title = case when title = p_code then 'tt_none' else title end, updated_at = now();
  delete from style_items where code = p_code;
  perform audit('style_item_delete', p_code, '{}'::jsonb);
  return jsonb_build_object('ok',true);
end $$;

-- ============ 7. Starter quests (admins can edit, add or hide them in Admin > Profile styles) ============
insert into style_tasks(title, description, kind, metric, target, reward_code, sort)
select v.t, v.d, v.k, v.m, v.n, v.r, v.s from (values
('Show your face','Add a profile photo.','auto','photo',1,'fr_bronze',10),
('Tell your story','Write a short bio on your profile (10+ letters).','auto','bio',1,'tt_rookie',20),
('Game ready','Add your game ID and in-game name.','auto','game_id',1,'nm_silver',30),
('First steps','Visit the site on 3 different days.','auto','visit_days',3,'fr_silver',40),
('Regular','Visit the site on 10 different days.','auto','visit_days',10,'tt_regular',50),
('Chatterbox','Send 25 chat messages.','auto','messages',25,'nm_frost',60),
('Have your say','Vote in 3 guild polls.','auto','polls',3,'bd_nebula',70),
('On a roll','Visit 5 days in a row.','auto','streak',5,'bd_ember',80),
('Collector','Earn 3 achievement badges.','auto','badges',3,'fr_amethyst',90),
('Warm up','Reach 1,500 glory in one week.','auto','weekly_glory',1500,'bd_room1',100),
('Devoted','Visit 14 days in a row.','auto','streak',14,'au_violet',110),
('Month with us','Visit the site on 30 different days.','auto','visit_days',30,'cd_obsidian',120),
('Garden party','Reach 2,000 glory in one week.','auto','weekly_glory',2000,'bd_room2',130),
('Rising star','Have a best week of 2,500 glory.','auto','best_week',2500,'nm_ember',140),
('Loud and proud','Send 100 chat messages.','auto','messages',100,'bd_room3',150),
('Rank collector','Earn 5 achievement badges.','auto','badges',5,'fr_diamond',160),
('Glory Hunter','Reach 3,000 glory in one week. Claim it in the same week.','auto','weekly_glory',3000,'fr_gold',170),
('Golden Profile','Reach 5,000 glory in one week. Claim it in the same week.','auto','weekly_glory',5000,'cd_gold',180),
('Rooftop regular','Visit the site on 60 different days.','auto','visit_days',60,'bd_room4',190),
('Five thousand strong','Reach 5,000 lifetime glory.','auto','lifetime_glory',5000,'cd_amethyst',200),
('Winter spirit','Send 250 chat messages.','auto','messages',250,'au_snow',210),
('Pollster','Vote in 10 guild polls.','auto','polls',10,'cd_ice',220),
('Heavy hitter','Reach 10,000 lifetime glory.','auto','lifetime_glory',10000,'bd_gold',230),
('Unbreakable','Visit 30 days in a row.','auto','streak',30,'bd_stars',240),
('Badge master','Earn 7 achievement badges.','auto','badges',7,'nm_gold',250),
('Ember lord','Visit the site on 100 different days.','auto','visit_days',100,'fr_ember',260),
('Veteran','Reach 25,000 lifetime glory.','auto','lifetime_glory',25000,'tt_veteran',270),
('Stargazer','Visit the site on 150 different days.','auto','visit_days',150,'bd_room5',280),
('Sparks fly','Reach 7,500 glory in one week.','auto','weekly_glory',7500,'au_sparkle',290),
('Hall of fame','Reach 50,000 lifetime glory.','auto','lifetime_glory',50000,'fr_royal',300),
('Win a guild tournament','Win a guild tournament. Add the tournament name and date; an admin will check it.','manual',null,1,'tt_champion',310),
('Bring a friend','Invite a new player who joins the guild. Write their name; an admin will check it.','manual',null,1,'tt_recruiter',320),
('Be Weekly MVP','Finish a week as the guild''s MVP. Tell us which week; an admin will check it.','manual',null,1,'tt_mvp',330),
('Guild creator','Make a guild video, poster or edit that the admins feature. Add a link or description.','manual',null,1,'au_embers',340)
) as v(t,d,k,m,n,r,s)
where not exists (select 1 from style_tasks x where x.title = v.t);

-- ============ 8. Optional: let logged-out visitors read published guild rules (the landing page has a Rules link). Remove the -- to enable ============
-- drop policy if exists rules_public on guild_rules;
-- create policy rules_public on guild_rules for select to anon using (published);

-- TripMatch Supabase backend
-- Run this file in the Supabase SQL editor. Authorization always uses auth.uid().

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trips (
  id uuid primary key default gen_random_uuid(),
  invite_code text unique not null,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  owner_token text,
  data jsonb not null default '{}'::jsonb,
  status text not null default 'collecting'
    check (status in ('collecting','grouping','pending_publish','published','voting','completed','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.preferences (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  participant_token text,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trip_id, user_id)
);

create table if not exists public.grouping_runs (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  version integer not null,
  status text not null default 'draft' check (status in ('draft','published','superseded')),
  rules jsonb not null default '{}'::jsonb,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  published_at timestamptz,
  unique (trip_id, version)
);

create table if not exists public.trip_groups (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.grouping_runs(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  external_id text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (run_id, external_id)
);

create table if not exists public.group_members (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.grouping_runs(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  group_id uuid not null references public.trip_groups(id) on delete cascade,
  preference_id uuid not null references public.preferences(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  unique (run_id, preference_id),
  unique (group_id, user_id)
);

create table if not exists public.votes (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.trip_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  destination text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, user_id)
);

create table if not exists public.activity_logs (
  id bigint generated always as identity primary key,
  trip_id uuid references public.trips(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists preferences_user_idx on public.preferences(user_id, updated_at desc);
create index if not exists grouping_runs_trip_idx on public.grouping_runs(trip_id, version desc);
create index if not exists group_members_user_idx on public.group_members(user_id, trip_id);
create index if not exists activity_logs_trip_idx on public.activity_logs(trip_id, created_at desc);

alter table public.profiles enable row level security;
alter table public.trips enable row level security;
alter table public.preferences enable row level security;
alter table public.grouping_runs enable row level security;
alter table public.trip_groups enable row level security;
alter table public.group_members enable row level security;
alter table public.votes enable row level security;
alter table public.activity_logs enable row level security;

-- Raw tables are intentionally private. The browser uses the RPCs below.
revoke all on table public.profiles, public.trips, public.preferences,
  public.grouping_runs, public.trip_groups, public.group_members,
  public.votes, public.activity_logs from anon, authenticated;

create or replace function public.trip_public_data(t public.trips)
returns jsonb
language sql immutable set search_path = public
as $$
  select jsonb_build_object(
    'id', t.invite_code,
    'name', t.data->>'name',
    'startDate', t.data->>'startDate',
    'endDate', t.data->>'endDate',
    'duration', t.data->'duration',
    'targetCount', coalesce(t.data->'targetCount', '25'::jsonb),
    'budgetTiers', coalesce(t.data->'budgetTiers', '[]'::jsonb),
    'destinations', coalesce(t.data->'destinations', '[]'::jsonb),
    'status', t.status,
    'createdAt', extract(epoch from t.created_at) * 1000,
    'cloud', true
  )
$$;

create or replace function public.create_trip(payload jsonb, owner_token text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_trip public.trips;
  v_invite text;
begin
  if v_user is null then raise exception '请先登录'; end if;
  if jsonb_typeof(payload) <> 'object' then raise exception '活动数据格式不正确'; end if;
  v_invite := nullif(btrim(payload->>'id'), '');
  if v_invite is null then v_invite := gen_random_uuid()::text; end if;

  insert into public.trips(invite_code, owner_user_id, owner_token, data)
  values (v_invite, v_user, nullif(owner_token, ''), payload - 'ownerToken' - 'ownerUserId')
  returning * into v_trip;

  insert into public.activity_logs(trip_id, actor_user_id, action)
  values (v_trip.id, v_user, 'trip_created');

  return public.trip_public_data(v_trip) || jsonb_build_object('ownerUserId', v_user);
end $$;

create or replace function public.get_trip(invite_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_trip public.trips;
begin
  if auth.uid() is null then raise exception '请先登录'; end if;
  select t.* into v_trip from public.trips t
  where t.invite_code = get_trip.invite_code and t.status <> 'cancelled';
  if not found then raise exception '活动不存在或已结束'; end if;
  return public.trip_public_data(v_trip);
end $$;

create or replace function public.submit_preference(
  invite_code text,
  participant_token text,
  payload jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_trip public.trips;
  v_pref public.preferences;
  v_data jsonb;
begin
  if v_user is null then raise exception '请先登录'; end if;
  if jsonb_typeof(payload) <> 'object' then raise exception '偏好数据格式不正确'; end if;
  select t.* into v_trip from public.trips t
  where t.invite_code = submit_preference.invite_code and t.status = 'collecting';
  if not found then raise exception '活动不存在或已停止收集'; end if;
  if v_trip.owner_user_id = v_user then raise exception '发起人不能填写自己的参与表'; end if;

  v_data := payload - 'userId' - 'participantToken' - 'tripId';
  insert into public.preferences(trip_id, user_id, participant_token, data)
  values (v_trip.id, v_user, nullif(participant_token, ''), v_data)
  on conflict (trip_id, user_id) do update
    set data = excluded.data,
        participant_token = coalesce(excluded.participant_token, public.preferences.participant_token),
        updated_at = now()
  returning * into v_pref;

  insert into public.activity_logs(trip_id, actor_user_id, action)
  values (v_trip.id, v_user, 'preference_submitted');

  return v_pref.data || jsonb_build_object(
    'id', v_pref.id,
    'tripId', v_trip.invite_code,
    'userId', v_user,
    'submittedAt', extract(epoch from v_pref.updated_at) * 1000
  );
end $$;

create or replace function public.get_user_dashboard()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_result jsonb;
begin
  if v_user is null then raise exception '请先登录'; end if;

  select jsonb_build_object(
    'trips', coalesce((
      select jsonb_agg(
        public.trip_public_data(t) || jsonb_build_object(
          'ownerUserId', t.owner_user_id,
          'preferences', coalesce((
            select jsonb_agg(p.data || jsonb_build_object(
              'id', p.id, 'tripId', t.invite_code, 'userId', p.user_id,
              'submittedAt', extract(epoch from p.updated_at) * 1000
            ) order by p.updated_at)
            from public.preferences p where p.trip_id = t.id
          ), '[]'::jsonb),
          'groups', coalesce((
            select jsonb_agg(g.data || jsonb_build_object(
              'id', g.external_id, 'tripId', t.invite_code, 'status', 'published',
              'memberIds', (select coalesce(jsonb_agg(m.preference_id), '[]'::jsonb) from public.group_members m where m.group_id=g.id)
            ) order by g.created_at)
            from public.trip_groups g
            join public.grouping_runs r on r.id = g.run_id
            where g.trip_id = t.id and r.status = 'published'
          ), '[]'::jsonb)
        ) order by t.created_at desc
      ) from public.trips t where t.owner_user_id = v_user
    ), '[]'::jsonb),
    'participations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'trip', public.trip_public_data(t),
        'preference', p.data || jsonb_build_object(
          'id', p.id, 'tripId', t.invite_code, 'userId', p.user_id,
          'submittedAt', extract(epoch from p.updated_at) * 1000
        ),
        'preferences', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', pm.preference_id, 'tripId', t.invite_code,
            'nickname', teammate.data->>'nickname'
          ))
          from public.group_members mine
          join public.grouping_runs rr on rr.id = mine.run_id and rr.status = 'published'
          join public.group_members pm on pm.group_id = mine.group_id
          join public.preferences teammate on teammate.id = pm.preference_id
          where mine.trip_id = t.id and mine.user_id = v_user
        ), '[]'::jsonb),
        'groups', coalesce((
          select jsonb_agg(g.data || jsonb_build_object(
            'id', g.external_id, 'tripId', t.invite_code, 'status', 'published',
            'memberIds', (select coalesce(jsonb_agg(m.preference_id), '[]'::jsonb) from public.group_members m where m.group_id=g.id)
          ))
          from public.group_members mine
          join public.grouping_runs rr on rr.id = mine.run_id and rr.status = 'published'
          join public.trip_groups g on g.id = mine.group_id
          where mine.trip_id = t.id and mine.user_id = v_user
        ), '[]'::jsonb)
      ) order by p.updated_at desc)
      from public.preferences p join public.trips t on t.id = p.trip_id
      where p.user_id = v_user
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.get_organizer_dashboard(owner_token text default null)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(public.get_user_dashboard()->'trips', '[]'::jsonb)
$$;

create or replace function public.get_participant_status(participant_token text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_dashboard jsonb; v_first jsonb;
begin
  v_dashboard := public.get_user_dashboard();
  select value into v_first
  from jsonb_array_elements(v_dashboard->'participations')
  order by (value->'preference'->>'submittedAt')::numeric desc nulls last
  limit 1;
  return v_first;
end $$;

create or replace function public.publish_groups(owner_token text, payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_trip public.trips;
  v_run public.grouping_runs;
  v_group public.trip_groups;
  v_item jsonb;
  v_member text;
  v_version integer;
  v_trip_code text;
begin
  if v_user is null then raise exception '请先登录'; end if;
  if jsonb_typeof(payload) <> 'array' or jsonb_array_length(payload) = 0 then
    raise exception '分组结果不能为空';
  end if;

  select value->>'tripId' into v_trip_code from jsonb_array_elements(payload) limit 1;
  if v_trip_code is null then raise exception '分组结果缺少活动 ID'; end if;
  if exists (select 1 from jsonb_array_elements(payload) x where x->>'tripId' is distinct from v_trip_code) then
    raise exception '一次只能发布一个活动的分组';
  end if;

  select t.* into v_trip from public.trips t
  where t.invite_code = v_trip_code and t.owner_user_id = v_user for update;
  if not found then raise exception '无权管理该活动'; end if;

  select coalesce(max(r.version), 0) + 1 into v_version
  from public.grouping_runs r where r.trip_id = v_trip.id;
  update public.grouping_runs set status = 'superseded'
  where trip_id = v_trip.id and status = 'published';

  insert into public.grouping_runs(trip_id, version, status, rules, created_by, published_at)
  values (v_trip.id, v_version, 'published', jsonb_build_object(
    'minimumOverlapDays', 3, 'maximumGroupSize', 8,
    'weights', jsonb_build_object('time', 40, 'budget', 25, 'destination', 25, 'style', 10)
  ), v_user, now()) returning * into v_run;

  for v_item in select value from jsonb_array_elements(payload) loop
    if jsonb_typeof(v_item->'memberIds') <> 'array' then raise exception '小组成员格式不正确'; end if;
    insert into public.trip_groups(run_id, trip_id, external_id, data)
    values (v_run.id, v_trip.id, v_item->>'id', v_item - 'memberIds')
    returning * into v_group;

    for v_member in select jsonb_array_elements_text(v_item->'memberIds') loop
      insert into public.group_members(run_id, trip_id, group_id, preference_id, user_id)
      select v_run.id, v_trip.id, v_group.id, p.id, p.user_id
      from public.preferences p
      where p.id = v_member::uuid and p.trip_id = v_trip.id;
      if not found then raise exception '分组包含无效参与人：%', v_member; end if;
    end loop;
  end loop;

  update public.trips set status = 'published', updated_at = now() where id = v_trip.id;
  insert into public.activity_logs(trip_id, actor_user_id, action, metadata)
  values (v_trip.id, v_user, 'groups_published', jsonb_build_object('version', v_version));
  return jsonb_build_object('ok', true, 'tripId', v_trip.invite_code, 'version', v_version);
end $$;

create or replace function public.cast_vote(group_external_id text, destination text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_group public.trip_groups;
  v_vote public.votes;
begin
  if v_user is null then raise exception '请先登录'; end if;
  select g.* into v_group
  from public.trip_groups g
  join public.grouping_runs r on r.id = g.run_id and r.status = 'published'
  join public.group_members m on m.group_id = g.id and m.user_id = v_user
  where g.external_id = group_external_id
  order by r.version desc limit 1;
  if not found then raise exception '你不在该已发布小组中'; end if;
  if not (coalesce(v_group.data->'commonDestinations', '[]'::jsonb) ? destination) then
    raise exception '该目的地不在小组候选范围内';
  end if;

  insert into public.votes(group_id, user_id, destination)
  values (v_group.id, v_user, destination)
  on conflict (group_id, user_id) do update
    set destination = excluded.destination, updated_at = now()
  returning * into v_vote;
  insert into public.activity_logs(trip_id, actor_user_id, action)
  values (v_group.trip_id, v_user, 'vote_cast');
  return jsonb_build_object(
    'id', v_vote.id, 'groupId', group_external_id,
    'selectedDestination', v_vote.destination, 'userId', v_user,
    'votedAt', extract(epoch from v_vote.updated_at) * 1000
  );
end $$;

revoke all on function public.trip_public_data(public.trips) from public, anon, authenticated;
revoke all on function public.create_trip(jsonb,text) from public, anon, authenticated;
revoke all on function public.get_trip(text) from public, anon, authenticated;
revoke all on function public.submit_preference(text,text,jsonb) from public, anon, authenticated;
revoke all on function public.get_user_dashboard() from public, anon, authenticated;
revoke all on function public.get_organizer_dashboard(text) from public, anon, authenticated;
revoke all on function public.get_participant_status(text) from public, anon, authenticated;
revoke all on function public.publish_groups(text,jsonb) from public, anon, authenticated;
revoke all on function public.cast_vote(text,text) from public, anon, authenticated;

grant execute on function public.create_trip(jsonb,text) to authenticated;
grant execute on function public.get_trip(text) to authenticated;
grant execute on function public.submit_preference(text,text,jsonb) to authenticated;
grant execute on function public.get_user_dashboard() to authenticated;
grant execute on function public.get_organizer_dashboard(text) to authenticated;
grant execute on function public.get_participant_status(text) to authenticated;
grant execute on function public.publish_groups(text,jsonb) to authenticated;
grant execute on function public.cast_vote(text,text) to authenticated;

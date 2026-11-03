create extension if not exists pgcrypto;

create table if not exists trips (
  id uuid primary key default gen_random_uuid(),
  invite_code text unique not null,
  owner_token text unique not null,
  data jsonb not null,
  status text not null default 'collecting',
  created_at timestamptz not null default now()
);

create table if not exists preferences (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references trips(id) on delete cascade,
  participant_token text unique not null,
  data jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists trip_groups (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references trips(id) on delete cascade,
  data jsonb not null,
  published boolean not null default false,
  created_at timestamptz not null default now()
);

alter table trips enable row level security;
alter table preferences enable row level security;
alter table trip_groups enable row level security;

create or replace function create_trip(payload jsonb, owner_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare row trips;
begin
  insert into trips(invite_code, owner_token, data)
  values (payload->>'id', owner_token, payload) returning * into row;
  return row.data || jsonb_build_object('ownerToken', owner_token, 'cloud', true);
end $$;

create or replace function get_trip(invite_code text)
returns jsonb language sql security definer set search_path = public as $$
  select data || jsonb_build_object('cloud', true) from trips where trips.invite_code = get_trip.invite_code;
$$;

create or replace function submit_preference(invite_code text, participant_token text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare trip_row trips; pref_row preferences;
begin
  select * into trip_row from trips where trips.invite_code = submit_preference.invite_code;
  if trip_row.id is null then raise exception '活动不存在或已结束'; end if;
  insert into preferences(trip_id, participant_token, data)
  values (trip_row.id, participant_token, payload)
  on conflict (participant_token) do update set data = excluded.data, updated_at = now()
  returning * into pref_row;
  return pref_row.data || jsonb_build_object('id', pref_row.id, 'tripId', invite_code, 'participantToken', participant_token);
end $$;

create or replace function get_organizer_dashboard(owner_token text)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(
    t.data || jsonb_build_object(
      'ownerToken', t.owner_token,
      'preferences', coalesce((select jsonb_agg(p.data || jsonb_build_object('id', p.id, 'tripId', t.invite_code)) from preferences p where p.trip_id=t.id), '[]'::jsonb),
      'groups', coalesce((select jsonb_agg(g.data || jsonb_build_object('status', case when g.published then 'published' else 'pending' end)) from trip_groups g where g.trip_id=t.id), '[]'::jsonb)
    ) order by t.created_at desc
  ), '[]'::jsonb) from trips t where t.owner_token = get_organizer_dashboard.owner_token;
$$;

create or replace function get_participant_status(participant_token text)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'trip', t.data,
    'preference', p.data || jsonb_build_object('id', p.id, 'tripId', t.invite_code),
    'preferences', coalesce((select jsonb_agg(jsonb_build_object('id', p2.id, 'nickname', p2.data->>'nickname')) from preferences p2 where p2.trip_id=t.id), '[]'::jsonb),
    'groups', coalesce((select jsonb_agg(g.data || jsonb_build_object('status', 'published')) from trip_groups g where g.trip_id=t.id and g.published), '[]'::jsonb)
  ) from preferences p join trips t on t.id=p.trip_id
  where p.participant_token = get_participant_status.participant_token;
$$;

create or replace function publish_groups(owner_token text, payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare trip_row trips; item jsonb;
begin
  select * into trip_row from trips where trips.owner_token = publish_groups.owner_token;
  if trip_row.id is null then raise exception '无权管理该活动'; end if;
  delete from trip_groups where trip_id=trip_row.id;
  for item in select * from jsonb_array_elements(payload) loop
    insert into trip_groups(trip_id, data, published) values (trip_row.id, item, true);
  end loop;
  update trips set status='grouped' where id=trip_row.id;
  return jsonb_build_object('ok', true);
end $$;

revoke all on trips, preferences, trip_groups from anon, authenticated;
grant execute on function create_trip(jsonb,text), get_trip(text), submit_preference(text,text,jsonb), get_organizer_dashboard(text), get_participant_status(text), publish_groups(text,jsonb) to anon, authenticated;

-- 0001_init.sql — السكيمة الأولى
-- تنفّذ القرارات: ADR-0001 (قاعدة واحدة مشتركة)، ADR-0003 (المُلّاك فقط)، ADR-0004 (أرشفة لا حذف)

create extension if not exists postgis;
create extension if not exists pgcrypto;

-- ───────────────────────── المستخدمون ─────────────────────────
-- لا رقم قومي، ولا صور مستندات، في أي عمود هنا أو في غيره
create table app_user (
  id             uuid primary key default gen_random_uuid(),
  phone          text        not null unique,
  display_name   text        not null,
  is_admin       boolean     not null default false,
  is_blocked     boolean     not null default false,
  blocked_reason text,
  created_at     timestamptz not null default now()
);

create table device_binding (
  id            uuid        primary key default gen_random_uuid(),
  user_id       uuid        not null references app_user(id),
  device_hash   text        not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  unique (user_id, device_hash)
);
create index device_binding_hash_idx on device_binding (device_hash);

-- ───────────────────────── التحقق ─────────────────────────
create type verification_level  as enum ('utility_bill','preliminary_deed','inheritance_deed','registered_deed');
create type verification_status as enum ('pending','approved','rejected');

-- ما يبقى بعد حذف المستندات: النتيجة والبصمة فقط
create table verification (
  id              uuid                primary key default gen_random_uuid(),
  user_id         uuid                not null references app_user(id),
  property_id     uuid,
  level           verification_level  not null,
  status          verification_status not null default 'pending',
  document_hash   text                not null,
  liveness_passed boolean             not null default false,
  name_matched    boolean             not null default false,
  reviewed_by     uuid                references app_user(id),
  reviewed_at     timestamptz,
  rejection_note  text,
  created_at      timestamptz         not null default now()
);
create index verification_queue_idx on verification (status, created_at);
create index verification_user_idx  on verification (user_id);

-- ───────────────────────── الوحدات ─────────────────────────
create type property_type  as enum ('apartment','house','villa','building_land','farm_land','shop');
create type license_status as enum ('licensed','unlicensed','unknown','reconciled');

create table property (
  id              uuid                primary key default gen_random_uuid(),
  owner_id        uuid                not null references app_user(id),
  type            property_type       not null,
  governorate     text                not null default 'الشرقية',
  city            text                not null,
  area_size       numeric(12,2)       not null check (area_size > 0),
  area_unit       text                not null check (area_unit in ('sqm','feddan')),
  location        geography(point,4326) not null,
  approx_radius_m integer             not null default 500 check (approx_radius_m > 0),
  license         license_status      not null default 'unknown',
  attributes      jsonb               not null default '{}',
  created_at      timestamptz         not null default now()
);
create index property_location_idx on property using gist (location);
create index property_city_idx     on property (city, type);
create index property_owner_idx    on property (owner_id);

-- ───────────────────────── الإعلانات ─────────────────────────
create type listing_purpose as enum ('sale','rent');
create type listing_status  as enum ('draft','pending_payment','published','expired','cancelled');

create table listing (
  id             uuid            primary key default gen_random_uuid(),
  property_id    uuid            not null references property(id),
  owner_id       uuid            not null references app_user(id),
  purpose        listing_purpose not null,
  price          numeric(14,2)   not null check (price > 0),
  price_per_unit numeric(14,2),
  status         listing_status  not null default 'draft',
  replaces_id    uuid            references listing(id),
  published_at   timestamptz,
  expires_at     timestamptz,
  ended_at       timestamptz,
  created_at     timestamptz     not null default now()
);
-- إعلان منشور واحد لكل وحدة لكل غرض
create unique index listing_one_active_idx
  on listing (property_id, purpose) where status = 'published';
create index listing_expiry_idx   on listing (status, expires_at);
create index listing_property_idx on listing (property_id, created_at);

create table listing_photo (
  id                   uuid        primary key default gen_random_uuid(),
  listing_id           uuid        not null references listing(id),
  storage_path         text        not null,
  content_hash         text        not null,
  captured_at          timestamptz not null,
  captured_at_location geography(point,4326),
  sort_order           smallint    not null default 0
);
-- بصمة الصورة: نفس الصورة في حسابين إشارة انتحال قوية
create index listing_photo_hash_idx    on listing_photo (content_hash);
create index listing_photo_listing_idx on listing_photo (listing_id, sort_order);

-- ───────────────────────── المحادثة ─────────────────────────
create table conversation (
  id          uuid        primary key default gen_random_uuid(),
  listing_id  uuid        not null references listing(id),
  property_id uuid        not null references property(id),
  buyer_id    uuid        not null references app_user(id),
  owner_id    uuid        not null references app_user(id),
  started_at  timestamptz not null default now(),
  unique (listing_id, buyer_id)
);
create index conversation_owner_idx on conversation (owner_id, started_at);
create index conversation_buyer_idx on conversation (buyer_id, started_at);

create table message (
  id              uuid        primary key default gen_random_uuid(),
  conversation_id uuid        not null references conversation(id),
  sender_id       uuid        not null references app_user(id),
  body            text        not null,
  phone_suspected boolean     not null default false,
  sent_at         timestamptz not null default now()
);
create index message_conversation_idx on message (conversation_id, sent_at);

-- ───────────────────────── الدفع والبلاغات ─────────────────────────
create type payment_status as enum ('pending','confirmed','failed');

create table payment (
  id           uuid           primary key default gen_random_uuid(),
  listing_id   uuid           not null references listing(id),
  payer_id     uuid           not null references app_user(id),
  amount       numeric(10,2)  not null check (amount > 0),
  method       text           not null,
  reference    text,
  status       payment_status not null default 'pending',
  confirmed_by uuid           references app_user(id),
  confirmed_at timestamptz,
  created_at   timestamptz    not null default now()
);
create index payment_listing_idx on payment (listing_id);

create table report (
  id          uuid        primary key default gen_random_uuid(),
  listing_id  uuid        not null references listing(id),
  reporter_id uuid        not null references app_user(id),
  reason      text        not null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now()
);
create index report_open_idx on report (resolved_at, created_at);

-- ───────────────────────── سجل الأحداث ─────────────────────────
-- مُضاف فقط. أساس التنبؤ بالأسعار لاحقاً.
create table event (
  id          bigserial   primary key,
  type        text        not null,
  actor_id    uuid        references app_user(id),
  property_id uuid        references property(id),
  listing_id  uuid        references listing(id),
  payload     jsonb       not null default '{}',
  occurred_at timestamptz not null default now()
);
create index event_type_idx     on event (type, occurred_at);
create index event_property_idx on event (property_id, occurred_at);
create index event_actor_idx    on event (actor_id, occurred_at);

-- المنع بصلاحيات قاعدة البيانات، لا بالاتفاق بين المطورين
create or replace function event_is_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'سجل الأحداث مُضاف فقط: لا تعديل ولا حذف';
end $$;

create trigger event_no_update before update on event
  for each row execute function event_is_append_only();
create trigger event_no_delete before delete on event
  for each row execute function event_is_append_only();

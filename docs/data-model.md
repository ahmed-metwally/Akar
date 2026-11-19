# نموذج البيانات

يلتزم هذا النموذج بثلاثة قرارات سابقة: المُلّاك فقط مع تحقق هوية (ADR-0003)، وأرشفة لا حذف مع حذف المستندات بعد التحقق (ADR-0004)، وقاعدة Postgres واحدة مشتركة بين الخدمات (ADR-0001). مصطلحاته من `GLOSSARY.md`.

## الكيانات وعلاقاتها

```
user ──< verification                 المستخدم وسجلات تحققه
user ──< property                     المالك ووحداته
property ──< listing                  الوحدة وإعلاناتها عبر الزمن
listing ──< listing_photo             صور الإعلان
listing ──< conversation ──< message  المحادثات على الإعلان
listing ──< payment                   مدفوعات الإعلان
user ──< device_binding               ربط الهوية بالأجهزة
listing ──< report                    بلاغات الباحثين
(كل ما سبق) ──> event                 سجل أحداث مُضاف لا يُعدَّل
```

**التمييز المحوري**: `property` هي الوحدة ككيان دائم، و`listing` هو عرضها بسعر ومدة. تغيير السعر يُنشئ `listing` جديداً ويُلغي القديم، ويظل الاثنان متعلّقين بنفس `property` — وهذا ما يجعل تاريخ السعر ممكناً.

## قواعد ثابتة لا يجوز كسرها

1. **لا حذف صفوف.** الإلغاء والانتهاء حالات، لا عمليات حذف. الاستثناء الوحيد هو ملفات المستندات في التخزين، لا صفوف قاعدة البيانات.
2. **لا تُخزَّن أرقام قومية ولا صور مستندات.** يُخزَّن من التحقق نتيجته ومستواه وتاريخه والمراجِع وبصمة المستند فقط.
3. **إعلان نشط واحد لكل وحدة** في كل غرض (بيع/إيجار) في أي لحظة.
4. **السعر إلزامي** في كل إعلان. لا يوجد "السعر عند الاتصال".
5. **كل تغيير ذي دلالة يولّد حدثاً** في `event`: تغيّر سعر، نشر، إلغاء، بدء محادثة، بحث، بلاغ.
6. **الموقع الدقيق لا يُعرض** قبل بدء محادثة؛ تُشتق منه دائرة تقريبية للعرض العام.

## السكيمة

```sql
create extension if not exists postgis;
create extension if not exists pgcrypto;

-- المستخدمون: لا رقم قومي، لا مستندات
create table app_user (
  id              uuid primary key default gen_random_uuid(),
  phone           text not null unique,          -- موثّق برمز لمرة واحدة
  display_name    text not null,
  is_blocked      boolean not null default false,
  blocked_reason  text,
  created_at      timestamptz not null default now()
);

-- ربط الهوية بالأجهزة: إشارة سلوكية ضد انتحال صفة المالك
create table device_binding (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references app_user(id),
  device_hash   text not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  unique (user_id, device_hash)
);

create type verification_level as enum (
  'utility_bill',      -- إيصال مرافق
  'preliminary_deed',  -- عقد ابتدائي
  'registered_deed',   -- سند مسجّل
  'inheritance_deed'   -- إعلام وراثة
);
create type verification_status as enum ('pending','approved','rejected');

-- سجل التحقق: ما يبقى بعد حذف المستندات
create table verification (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references app_user(id),
  property_id     uuid,                            -- دليل ملكية لوحدة بعينها
  level           verification_level not null,
  status          verification_status not null default 'pending',
  document_hash   text not null,                   -- بصمة المستند، لا محتواه
  liveness_passed boolean not null default false,
  name_matched    boolean not null default false,
  reviewed_by     uuid references app_user(id),
  reviewed_at     timestamptz,
  rejection_note  text,
  created_at      timestamptz not null default now()
);

create type property_type as enum ('apartment','house','villa','building_land','farm_land','shop');
create type license_status as enum ('licensed','unlicensed','unknown','reconciled');

-- الوحدة: كيان دائم تتعلق به كل إعلاناتها
create table property (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references app_user(id),
  type           property_type not null,
  governorate    text not null default 'الشرقية',
  city           text not null,
  area_size       numeric(12,2) not null,
  area_unit       text not null,                   -- متر مربع / فدان
  location        geography(point,4326) not null,  -- الموقع الدقيق
  approx_radius_m integer not null default 500,    -- نصف قطر العرض العام
  license         license_status not null default 'unknown',
  attributes      jsonb not null default '{}',     -- حقول خاصة بكل نوع
  created_at      timestamptz not null default now()
);
create index on property using gist (location);
create index on property (city, type);

create type listing_purpose as enum ('sale','rent');
create type listing_status  as enum ('draft','pending_payment','published','expired','cancelled');

-- الإعلان: عرض وحدة بسعر ومدة
create table listing (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references property(id),
  owner_id      uuid not null references app_user(id),
  purpose       listing_purpose not null,
  price         numeric(14,2) not null check (price > 0),
  price_per_unit numeric(14,2),                    -- سعر المتر/الفدان، محسوب
  status        listing_status not null default 'draft',
  replaces_id   uuid references listing(id),       -- الإعلان الذي حلّ محله عند تغيير السعر
  published_at  timestamptz,
  expires_at    timestamptz,
  ended_at      timestamptz,
  created_at    timestamptz not null default now()
);
-- إعلان نشط واحد لكل وحدة لكل غرض
create unique index one_active_listing
  on listing (property_id, purpose) where status = 'published';
create index on listing (status, expires_at);

-- الصور: تُلتقط داخل التطبيق، بختم زمني وموقع
create table listing_photo (
  id            uuid primary key default gen_random_uuid(),
  listing_id    uuid not null references listing(id),
  storage_path  text not null,
  content_hash  text not null,                     -- كشف تكرار الصور بين الحسابات
  captured_at   timestamptz not null,
  captured_at_location geography(point,4326),
  sort_order    smallint not null default 0
);
create index on listing_photo (content_hash);

create table conversation (
  id          uuid primary key default gen_random_uuid(),
  listing_id  uuid not null references listing(id),
  property_id uuid not null references property(id),
  buyer_id    uuid not null references app_user(id),
  owner_id    uuid not null references app_user(id),
  started_at  timestamptz not null default now(),
  unique (listing_id, buyer_id)
);

create table message (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversation(id),
  sender_id       uuid not null references app_user(id),
  body            text not null,
  phone_suspected boolean not null default false,  -- رصد تسريب الأرقام، دون حظر
  sent_at         timestamptz not null default now()
);
create index on message (conversation_id, sent_at);

create type payment_status as enum ('pending','confirmed','failed');

-- الدفع: مؤجَّل عن الإصدار الأول، والجدول قائم ليستقبل التأكيد اليدوي
create table payment (
  id            uuid primary key default gen_random_uuid(),
  listing_id    uuid not null references listing(id),
  payer_id      uuid not null references app_user(id),
  amount        numeric(10,2) not null,
  method        text not null,                     -- instapay ...
  reference     text,                              -- رقم العملية
  status        payment_status not null default 'pending',
  confirmed_by  uuid references app_user(id),
  confirmed_at  timestamptz,
  created_at    timestamptz not null default now()
);

create table report (
  id          uuid primary key default gen_random_uuid(),
  listing_id  uuid not null references listing(id),
  reporter_id uuid not null references app_user(id),
  reason      text not null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now()
);

-- سجل الأحداث: مُضاف فقط، أساس التنبؤ لاحقاً
create table event (
  id          bigserial primary key,
  type        text not null,          -- price_changed, listing_published, contact_started, search_performed ...
  actor_id    uuid references app_user(id),
  property_id uuid references property(id),
  listing_id  uuid references listing(id),
  payload     jsonb not null default '{}',
  occurred_at timestamptz not null default now()
);
create index on event (type, occurred_at);
create index on event (property_id, occurred_at);
```

## ملاحظات تنفيذية

- **منع التعديل والحذف على `event`** بصلاحيات قاعدة البيانات، لا بالاتفاق بين المطورين.
- **RLS هو حدّ الأمان الفعلي** ما دامت القاعدة مشتركة بين الخدمات: المالك يرى وحداته وإعلاناته ومحادثاته فقط، والباحث يرى المنشور ومحادثاته، وطابور المراجعة للإدارة وحدها.
- **`attributes` بصيغة jsonb** يستوعب اختلاف الحقول بين الشقة والأرض دون جدول لكل نوع؛ تُفرض الحقول الإلزامية لكل نوع في طبقة التطبيق.
- **`content_hash` للصور** هو أرخص كاشف لانتحال صفة المالك: نفس الصورة في حسابين إشارة قوية.
- **تاريخ السعر** يُقرأ من `listing` عبر `property_id` مرتبة زمنياً، ويدعمه `event` بتفصيل أدق.
- **انتهاء المدة** مهمة مجدولة تنقل `published` إلى `expired` وتولّد حدثاً.

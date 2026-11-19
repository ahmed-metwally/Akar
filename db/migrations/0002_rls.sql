-- 0002_rls.sql — أمان مستوى الصف
-- القاعدة مشتركة بين كل الخدمات (ADR-0001)، فـ RLS هو حدّ الأمان الفعلي لا جدار الشبكة.
-- current_setting('app.user_id') يضبطه كل طلب بهوية المستخدم.

create or replace function app_current_user() returns uuid
language sql stable as $$
  select nullif(current_setting('app.user_id', true), '')::uuid
$$;

create or replace function app_is_admin() returns boolean
language sql stable as $$
  select coalesce((select is_admin from app_user where id = app_current_user()), false)
$$;

alter table app_user     enable row level security;
alter table property     enable row level security;
alter table listing      enable row level security;
alter table listing_photo enable row level security;
alter table verification enable row level security;
alter table conversation enable row level security;
alter table message      enable row level security;
alter table payment      enable row level security;
alter table report       enable row level security;

-- المستخدم يرى نفسه؛ الإدارة ترى الجميع
create policy user_self on app_user for select
  using (id = app_current_user() or app_is_admin());

-- الوحدات: المالك يرى وحداته؛ وحدات الإعلانات المنشورة مرئية للجميع
create policy property_read on property for select
  using (
    owner_id = app_current_user()
    or app_is_admin()
    or exists (select 1 from listing l where l.property_id = property.id and l.status = 'published')
  );
create policy property_write on property for all
  using (owner_id = app_current_user()) with check (owner_id = app_current_user());

-- الإعلانات: المنشور عام، وغير المنشور لصاحبه
create policy listing_read on listing for select
  using (status = 'published' or owner_id = app_current_user() or app_is_admin());
create policy listing_write on listing for all
  using (owner_id = app_current_user()) with check (owner_id = app_current_user());

create policy photo_read on listing_photo for select
  using (exists (
    select 1 from listing l where l.id = listing_photo.listing_id
      and (l.status = 'published' or l.owner_id = app_current_user() or app_is_admin())
  ));

-- التحقق: صاحبه والإدارة فقط. لا يُعرض لأحد غيرهما.
create policy verification_read on verification for select
  using (user_id = app_current_user() or app_is_admin());

-- المحادثة: طرفاها فقط. الإدارة لا تقرأ الرسائل افتراضياً.
create policy conversation_read on conversation for select
  using (buyer_id = app_current_user() or owner_id = app_current_user());
create policy message_read on message for select
  using (exists (
    select 1 from conversation c where c.id = message.conversation_id
      and (c.buyer_id = app_current_user() or c.owner_id = app_current_user())
  ));
create policy message_send on message for insert
  with check (sender_id = app_current_user() and exists (
    select 1 from conversation c where c.id = message.conversation_id
      and (c.buyer_id = app_current_user() or c.owner_id = app_current_user())
  ));

create policy payment_read on payment for select
  using (payer_id = app_current_user() or app_is_admin());

create policy report_insert on report for insert
  with check (reporter_id = app_current_user());
create policy report_read on report for select
  using (reporter_id = app_current_user() or app_is_admin());

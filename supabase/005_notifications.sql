-- =====================================================================
--  مكتبتي — تحديث 005: الإشعارات بالإيميل
--  كيفاش: Supabase > SQL Editor > New snippet > نسخ هاد الملف كامل > Run
--  (يقدر يتعاود يتشغل بلا مشاكل)
--
--  الإيميلات كتمشي عبر Brevo (فابور: 300 إيميل ف النهار).
--  المفتاح والإيميل اللي كيصيفط كيتخباو ف Supabase Vault (ماشي ف هاد الملف):
--  شوف الخطوة اللخرة ف الأسفل.
-- =====================================================================

-- 1. pg_net: باش القاعدة تقدر تصيفط طلبات HTTP (للـ Brevo)
create extension if not exists pg_net with schema extensions;

-- 2. الإعدادات ديال كل واحد + آخر مرة كان ف الموقع
create table if not exists public.notify_settings (
  user_id       uuid primary key default auth.uid() references public.profiles(id) on delete cascade,
  email_enabled boolean not null default true,
  last_seen     timestamptz not null default now()
);
alter table public.notify_settings enable row level security;
drop policy if exists notify_settings_select on public.notify_settings;
create policy notify_settings_select on public.notify_settings for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists notify_settings_insert on public.notify_settings;
create policy notify_settings_insert on public.notify_settings for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists notify_settings_update on public.notify_settings;
create policy notify_settings_update on public.notify_settings for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.notify_settings from anon, authenticated;
grant select on public.notify_settings to authenticated;
grant insert (user_id, email_enabled) on public.notify_settings to authenticated;
grant update (user_id, email_enabled) on public.notify_settings to authenticated;   -- upsert كيعاود يكتب user_id (RLS كتمنع تبدلو)

-- "راني هنا": الموقع كيعيط لهادي كل دقيقة ملي يكون محلول
create or replace function public.touch_presence()
returns void language sql volatile security definer set search_path = '' as $$
  insert into public.notify_settings (user_id, last_seen) values (auth.uid(), now())
  on conflict (user_id) do update set last_seen = now();
$$;
revoke execute on function public.touch_presence() from public, anon;
grant execute on function public.touch_presence() to authenticated;

-- 3. باش ما نعمروش الإيميل: إيميل واحد لكل نوع ف مدة معينة
create table if not exists public.email_log (
  user_id uuid not null references public.profiles(id) on delete cascade,
  key     text not null,
  sent_at timestamptz not null default now(),
  primary key (user_id, key)
);
alter table public.email_log enable row level security;   -- بلا policies: حتى واحد ما يقدر يقراها من الموقع
revoke all on public.email_log from anon, authenticated;

-- واش نصيفطو؟ (الإيميل مشعول + ماشي ف الموقع دابا + ما صيفطناش نفس الحاجة قريب)
create or replace function public.mk_should_email(target uuid, k text, cooldown interval, only_if_away boolean)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare s public.notify_settings%rowtype; ok boolean := false;
begin
  select * into s from public.notify_settings where user_id = target;
  if found and not s.email_enabled then return false; end if;
  if only_if_away and found and s.last_seen > now() - interval '3 minutes' then return false; end if;
  insert into public.email_log (user_id, key, sent_at) values (target, k, now())
  on conflict (user_id, key) do update set sent_at = now()
    where public.email_log.sent_at < now() - cooldown
  returning true into ok;
  return coalesce(ok, false);
end;
$$;

create or replace function public.mk_esc(s text)
returns text language sql immutable set search_path = '' as $$
  select replace(replace(replace(replace(coalesce(s, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;

-- 4. كيصيفط الإيميل عبر Brevo (إلا ما كاينش المفتاح ف Vault، ما كيدير والو)
create or replace function public.mk_send_email(target uuid, subject text, title text, body_html text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  api_key text; sender text; to_email text; to_name text;
  site text := 'https://medo01012001.github.io/mektabati/';
  html text;
begin
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  select decrypted_secret into sender  from vault.decrypted_secrets where name = 'mail_from' limit 1;
  if api_key is null or sender is null then return; end if;
  select u.email into to_email from auth.users u where u.id = target;
  if to_email is null then return; end if;
  select p.username into to_name from public.profiles p where p.id = target;

  html := '<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;background:#f3f4f6;padding:24px">'
       || '<div style="max-width:480px;margin:auto;background:#fff;border-radius:16px;padding:24px;border:1px solid #e5e7eb">'
       || '<div style="font-size:22px;font-weight:bold;color:#4f46e5;margin-bottom:12px">📚 مكتبتي</div>'
       || '<p style="color:#6b7280;margin:0 0 8px">السلام ' || public.mk_esc(to_name) || '،</p>'
       || '<h2 style="color:#111827;font-size:18px;margin:0 0 12px">' || title || '</h2>'
       || '<div style="color:#374151;font-size:15px;line-height:1.7">' || body_html || '</div>'
       || '<a href="' || site || '" style="display:inline-block;margin-top:20px;background:#4f46e5;color:#fff;text-decoration:none;padding:12px 24px;border-radius:12px;font-weight:bold">افتح مكتبتي</a>'
       || '<p style="color:#9ca3af;font-size:12px;margin-top:24px">تقدر تطفي هاد الإيميلات من الملف الشخصي ← الإشعارات.</p>'
       || '</div></div>';

  perform net.http_post(
    url     := 'https://api.brevo.com/v3/smtp/email',
    body    := jsonb_build_object(
                 'sender',      jsonb_build_object('name', 'مكتبتي', 'email', sender),
                 'to',          jsonb_build_array(jsonb_build_object('email', to_email)),
                 'subject',     subject,
                 'htmlContent', html),
    headers := jsonb_build_object('api-key', api_key, 'content-type', 'application/json', 'accept', 'application/json')
  );
end;
$$;

revoke execute on function public.mk_should_email(uuid, text, interval, boolean) from public, anon, authenticated;
revoke execute on function public.mk_send_email(uuid, text, text, text) from public, anon, authenticated;

-- 5. الأحداث اللي كتصيفط إيميل
-- 💬 رسالة جديدة (ولا كتاب تشارك): غير إلا ما كانش ف الموقع، وإيميل واحد لكل صديق ف 30 دقيقة
create or replace function public.mk_notify_message()
returns trigger language plpgsql security definer set search_path = '' as $$
declare who text; book_title text; body text;
begin
  begin
    if public.mk_should_email(new.recipient_id, 'msg:' || new.sender_id, interval '30 minutes', true) then
      select username into who from public.profiles where id = new.sender_id;
      if new.book_id is not null then
        select b.title into book_title from public.books b where b.id = new.book_id;
      end if;
      body := case when new.body is not null
                then '<div style="background:#eef2ff;border-radius:12px;padding:12px 16px">' || public.mk_esc(left(new.body, 300)) || '</div>'
                else '' end
           || case when book_title is not null
                then '<p>📚 شارك معاك كتاب: <b>' || public.mk_esc(book_title) || '</b></p>'
                else '' end;
      perform public.mk_send_email(new.recipient_id,
        '💬 رسالة جديدة من ' || coalesce(who, 'صديق'),
        '💬 ' || public.mk_esc(coalesce(who, 'صديق')) || ' صيفط ليك رسالة',
        body);
    end if;
  exception when others then null;   -- الإيميل عمرو ما يوقف الرسالة
  end;
  return new;
end;
$$;
drop trigger if exists mk_notify_message on public.messages;
create trigger mk_notify_message after insert on public.messages
  for each row execute function public.mk_notify_message();

-- 👥 طلب صداقة جديد / قبلو الطلب ديالك
create or replace function public.mk_notify_friendship()
returns trigger language plpgsql security definer set search_path = '' as $$
declare who text;
begin
  begin
    if tg_op = 'INSERT' and new.status = 'pending' then
      if public.mk_should_email(new.addressee_id, 'freq:' || new.requester_id, interval '1 day', false) then
        select username into who from public.profiles where id = new.requester_id;
        perform public.mk_send_email(new.addressee_id,
          '👥 طلب صداقة جديد من ' || coalesce(who, 'قارئ'),
          '👥 ' || public.mk_esc(coalesce(who, 'قارئ')) || ' بغا يولي صديقك',
          '<p>دخل لـ "الأصدقاء" باش تقبل ولا ترفض الطلب.</p>');
      end if;
    elsif tg_op = 'UPDATE' and new.status = 'accepted' and old.status = 'pending' then
      if public.mk_should_email(new.requester_id, 'facc:' || new.addressee_id, interval '1 day', false) then
        select username into who from public.profiles where id = new.addressee_id;
        perform public.mk_send_email(new.requester_id,
          '🎉 ' || coalesce(who, 'قارئ') || ' قبل طلب الصداقة ديالك',
          '🎉 ' || public.mk_esc(coalesce(who, 'قارئ')) || ' ولا صديقك',
          '<p>دابا تقدرو تهضرو ف المحادثة وتشاركو الكتب.</p>');
      end if;
    end if;
  exception when others then null;
  end;
  return new;
end;
$$;
drop trigger if exists mk_notify_friendship on public.friendships;
create trigger mk_notify_friendship after insert or update of status on public.friendships
  for each row execute function public.mk_notify_friendship();

-- ⭐ شي واحد قيم كتاب رفعتيه
create or replace function public.mk_notify_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare who text; b record;
begin
  begin
    select id, title, owner_id into b from public.books where id = new.book_id;
    if b.owner_id is not null and b.owner_id <> new.user_id
       and public.mk_should_email(b.owner_id, 'rev:' || new.book_id || ':' || new.user_id, interval '1 day', false) then
      select username into who from public.profiles where id = new.user_id;
      perform public.mk_send_email(b.owner_id,
        '⭐ تقييم جديد على "' || left(b.title, 60) || '"',
        '⭐ ' || public.mk_esc(coalesce(who, 'قارئ')) || ' قيم الكتاب ديالك',
        '<p><b>' || public.mk_esc(b.title) || '</b> — ' || repeat('⭐', new.rating) || '</p>'
        || case when new.body <> '' then '<div style="background:#fef3c7;border-radius:12px;padding:12px 16px">' || public.mk_esc(left(new.body, 300)) || '</div>' else '' end);
    end if;
  exception when others then null;
  end;
  return new;
end;
$$;
drop trigger if exists mk_notify_review on public.reviews;
create trigger mk_notify_review after insert on public.reviews
  for each row execute function public.mk_notify_review();

-- =====================================================================
--  الخطوة اللخرة (مرة وحدة، ف snippet بوحدو، ماشي هنا):
--  بدل KEY_DIALK و EMAIL_DIALK وشغل هادشي ف SQL Editor:
--
--  do $$ begin
--    delete from vault.secrets where name in ('brevo_api_key', 'mail_from');
--    perform vault.create_secret('KEY_DIALK',   'brevo_api_key');
--    perform vault.create_secret('EMAIL_DIALK', 'mail_from');
--  end $$;
-- =====================================================================

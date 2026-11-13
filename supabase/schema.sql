-- =====================================================================
--  مكتبتي — قاعدة البيانات ديال Supabase
--  كيفاش: Supabase Dashboard > SQL Editor > New query > نسخ هاد الملف كامل > Run
--  الملف يقدر يتعاود يتشغل بلا مشاكل (كيمسح القواعد القديمة وكيعاود يديرها)
--  من بعد هاد الملف، شغل التحديثات بالترتيب: 002_readers.sql ثم 003_public_activity.sql ثم 004_word_files.sql ثم 005_notifications.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. الجداول
-- ---------------------------------------------------------------------

-- الحسابات (كتتصايب بوحدها ملي كيتسجل شي واحد)
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null check (char_length(btrim(username)) between 1 and 50),
  bio         text not null default '' check (char_length(bio) <= 500),
  avatar_path text,
  friend_code text not null unique,
  created_at  timestamptz not null default now()
);

-- الكتب: visibility = private (غير أنا) / friends (الأصدقاء) / public (الجميع)
create table if not exists public.books (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  title       text not null check (char_length(btrim(title)) between 1 and 200),
  author      text not null default '' check (char_length(author) <= 200),
  category    text not null check (char_length(category) between 1 and 100),
  visibility  text not null default 'friends' check (visibility in ('private', 'friends', 'public')),
  pdf_path    text not null unique,
  cover_path  text,
  total_pages integer not null default 1 check (total_pages > 0),
  file_size   bigint check (file_size is null or file_size > 0),
  created_at  timestamptz not null default now()
);
create index if not exists books_owner_idx on public.books(owner_id, created_at desc);
create index if not exists books_visibility_idx on public.books(visibility, created_at desc);

-- الصداقة: طلب (pending) ومن بعد قبول (accepted)
create table if not exists public.friendships (
  id           bigint generated always as identity primary key,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at   timestamptz not null default now(),
  check (requester_id <> addressee_id)
);
create unique index if not exists friendships_pair_idx
  on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index if not exists friendships_addressee_idx on public.friendships(addressee_id);
create index if not exists friendships_requester_idx on public.friendships(requester_id);

-- الرسائل الخاصة (نص، ولا كتاب مشارك، ولا بجوج)
create table if not exists public.messages (
  id           bigint generated always as identity primary key,
  sender_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  body         text check (body is null or char_length(body) between 1 and 2000),
  book_id      uuid references public.books(id) on delete cascade,
  created_at   timestamptz not null default now(),
  read_at      timestamptz,
  check (body is not null or book_id is not null),
  check (sender_id <> recipient_id)
);
create index if not exists messages_recipient_idx on public.messages(recipient_id, created_at desc);
create index if not exists messages_sender_idx on public.messages(sender_id, created_at desc);
create index if not exists messages_book_idx on public.messages(book_id) where book_id is not null;

-- المكتبة ديال كل مستخدم: الكتب اللي زادها + فين وصل فيها
create table if not exists public.book_state (
  user_id      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  book_id      uuid not null references public.books(id) on delete cascade,
  current_page integer not null default 1 check (current_page >= 1),
  progress     smallint not null default 0 check (progress between 0 and 100),
  is_read      boolean not null default false,
  is_favorite  boolean not null default false,
  added_at     timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (user_id, book_id)
);
create index if not exists book_state_book_idx on public.book_state(book_id);
create index if not exists book_state_updated_idx on public.book_state(updated_at desc);

-- الملاحظات والاقتباسات (خاصة بمولاها فقط)
create table if not exists public.book_notes (
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  book_id    uuid not null references public.books(id) on delete cascade,
  content    text not null default '' check (char_length(content) <= 20000),
  updated_at timestamptz not null default now(),
  primary key (user_id, book_id)
);

-- التقييمات والمراجعات
create table if not exists public.reviews (
  book_id    uuid not null references public.books(id) on delete cascade,
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  rating     smallint not null check (rating between 1 and 5),
  body       text not null default '' check (char_length(body) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (book_id, user_id)
);
create index if not exists reviews_user_idx on public.reviews(user_id);


-- ---------------------------------------------------------------------
-- 2. الدوال
-- ---------------------------------------------------------------------

-- كود صداقة من 6 حروف/أرقام (بلا حروف كتشابه بحال O/0 و I/1)
create or replace function public.generate_friend_code()
returns text language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles p where p.friend_code = code);
  end loop;
  return code;
end;
$$;

-- ملي كيتسجل مستخدم جديد كنصايبو ليه profile
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, username, friend_code)
  values (
    new.id,
    left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'username'), ''), split_part(new.email, '@', 1)), 50),
    public.generate_friend_code()
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- واش هاد المستخدم صاحبي؟
create or replace function public.is_friend(other uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.requester_id = auth.uid() and f.addressee_id = other)
        or (f.addressee_id = auth.uid() and f.requester_id = other))
  );
$$;

-- واش نقدر نشوف هاد الكتاب؟ (القاعدة الوحيدة ديال الخصوصية، كتستعملها الجداول والملفات)
create or replace function public.can_view_book(bid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.books b
    where b.id = bid
      and (
        b.owner_id = auth.uid()
        or b.visibility = 'public'
        or (b.visibility = 'friends' and public.is_friend(b.owner_id))
        -- كتاب خاص ولكن مولاه صيفطو ليا ف الـ chat
        or exists (
          select 1 from public.messages m
          where m.book_id = b.id and m.recipient_id = auth.uid() and m.sender_id = b.owner_id
        )
      )
  );
$$;

-- واش نقدر نحمل هاد الـ PDF؟
create or replace function public.can_view_pdf(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.books b
    where b.pdf_path = object_name and public.can_view_book(b.id)
  );
$$;

-- صيفط طلب صداقة بالكود. كترجع: sent / accepted / already_sent / already_friends / not_found / self
create or replace function public.send_friend_request(code text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  target uuid;
  existing public.friendships%rowtype;
begin
  if me is null then
    raise exception 'not authenticated';
  end if;

  select p.id into target from public.profiles p where p.friend_code = upper(btrim(code));
  if target is null then return 'not_found'; end if;
  if target = me then return 'self'; end if;

  select * into existing from public.friendships f
  where least(f.requester_id, f.addressee_id) = least(me, target)
    and greatest(f.requester_id, f.addressee_id) = greatest(me, target);

  if found then
    if existing.status = 'accepted' then return 'already_friends'; end if;
    -- هو اللي صيفط ليا طلب من قبل: نقبلو ديريكت
    if existing.addressee_id = me then
      update public.friendships set status = 'accepted' where id = existing.id;
      return 'accepted';
    end if;
    return 'already_sent';
  end if;

  insert into public.friendships (requester_id, addressee_id) values (me, target);
  return 'sent';
end;
$$;

-- تحديث updated_at أوتوماتيكيا
create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists book_state_touch on public.book_state;
create trigger book_state_touch before update on public.book_state
  for each row execute function public.touch_updated_at();
drop trigger if exists book_notes_touch on public.book_notes;
create trigger book_notes_touch before update on public.book_notes
  for each row execute function public.touch_updated_at();
drop trigger if exists reviews_touch on public.reviews;
create trigger reviews_touch before update on public.reviews
  for each row execute function public.touch_updated_at();

-- الصلاحيات ديال الدوال
revoke execute on function public.generate_friend_code() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.touch_updated_at() from public, anon, authenticated;
revoke execute on function public.is_friend(uuid) from public, anon;
revoke execute on function public.can_view_book(uuid) from public, anon;
revoke execute on function public.can_view_pdf(text) from public, anon;
revoke execute on function public.send_friend_request(text) from public, anon;
grant execute on function public.is_friend(uuid) to authenticated;
grant execute on function public.can_view_book(uuid) to authenticated;
grant execute on function public.can_view_pdf(text) to authenticated;
grant execute on function public.send_friend_request(text) to authenticated;


-- ---------------------------------------------------------------------
-- 3. صلاحيات الجداول (شنو يقدر يدير المستخدم ف كل جدول)
-- ---------------------------------------------------------------------
revoke all on public.profiles, public.books, public.friendships, public.messages,
              public.book_state, public.book_notes, public.reviews from anon, authenticated;

grant select on public.profiles to authenticated;
grant update (username, bio, avatar_path) on public.profiles to authenticated;   -- كود الصداقة ما يتبدلش

grant select, insert, update, delete on public.books to authenticated;
grant select, delete on public.friendships to authenticated;
grant update (status) on public.friendships to authenticated;                    -- الطلبات كتتصيفط غير بـ send_friend_request
grant select, insert, delete on public.messages to authenticated;
grant update (read_at) on public.messages to authenticated;                      -- غير "تقرات"
grant select, insert, update, delete on public.book_state to authenticated;
grant select, insert, update, delete on public.book_notes to authenticated;
grant select, insert, update, delete on public.reviews to authenticated;


-- ---------------------------------------------------------------------
-- 4. قواعد الأمان (Row Level Security)
-- ---------------------------------------------------------------------
alter table public.profiles    enable row level security;
alter table public.books       enable row level security;
alter table public.friendships enable row level security;
alter table public.messages    enable row level security;
alter table public.book_state  enable row level security;
alter table public.book_notes  enable row level security;
alter table public.reviews     enable row level security;

-- profiles: كنشوف راسي، والناس اللي بيناتنا طلب/صداقة، واللي عندهم كتب عامة، واللي كتبو مراجعات كنشوفها
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (
  id = (select auth.uid())
  or exists (
    select 1 from public.friendships f
    where (f.requester_id = (select auth.uid()) and f.addressee_id = profiles.id)
       or (f.addressee_id = (select auth.uid()) and f.requester_id = profiles.id)
  )
  or exists (select 1 from public.books b where b.owner_id = profiles.id and b.visibility = 'public')
  or exists (select 1 from public.reviews r where r.user_id = profiles.id)
);
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- books
drop policy if exists books_select on public.books;
create policy books_select on public.books for select to authenticated
  using (public.can_view_book(id));
drop policy if exists books_insert on public.books;
create policy books_insert on public.books for insert to authenticated with check (
  owner_id = (select auth.uid())
  and split_part(pdf_path, '/', 1) = (select auth.uid())::text
  and (cover_path is null or split_part(cover_path, '/', 1) = (select auth.uid())::text)
);
drop policy if exists books_update on public.books;
create policy books_update on public.books for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (
    owner_id = (select auth.uid())
    and split_part(pdf_path, '/', 1) = (select auth.uid())::text
    and (cover_path is null or split_part(cover_path, '/', 1) = (select auth.uid())::text)
  );
drop policy if exists books_delete on public.books;
create policy books_delete on public.books for delete to authenticated
  using (owner_id = (select auth.uid()));

-- friendships
drop policy if exists friendships_select on public.friendships;
create policy friendships_select on public.friendships for select to authenticated
  using ((select auth.uid()) in (requester_id, addressee_id));
drop policy if exists friendships_accept on public.friendships;
create policy friendships_accept on public.friendships for update to authenticated
  using (addressee_id = (select auth.uid()))
  with check (addressee_id = (select auth.uid()) and status = 'accepted');
drop policy if exists friendships_delete on public.friendships;
create policy friendships_delete on public.friendships for delete to authenticated
  using ((select auth.uid()) in (requester_id, addressee_id));

-- messages: غير بين الأصدقاء، والكتاب المشارك خاصو يكون كنقدر نشوفو
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using ((select auth.uid()) in (sender_id, recipient_id));
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated with check (
  sender_id = (select auth.uid())
  and public.is_friend(recipient_id)
  and (book_id is null or public.can_view_book(book_id))
);
drop policy if exists messages_mark_read on public.messages;
create policy messages_mark_read on public.messages for update to authenticated
  using (recipient_id = (select auth.uid())) with check (recipient_id = (select auth.uid()));
drop policy if exists messages_delete on public.messages;
create policy messages_delete on public.messages for delete to authenticated
  using (sender_id = (select auth.uid()));

-- book_state: ديالي كامل، والأصدقاء كيشوفو النشاط ديالي غير على الكتب اللي يقدرو يشوفوها
drop policy if exists book_state_select on public.book_state;
create policy book_state_select on public.book_state for select to authenticated using (
  user_id = (select auth.uid())
  or (public.is_friend(user_id) and public.can_view_book(book_id))
);
drop policy if exists book_state_insert on public.book_state;
create policy book_state_insert on public.book_state for insert to authenticated
  with check (user_id = (select auth.uid()) and public.can_view_book(book_id));
drop policy if exists book_state_update on public.book_state;
create policy book_state_update on public.book_state for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists book_state_delete on public.book_state;
create policy book_state_delete on public.book_state for delete to authenticated
  using (user_id = (select auth.uid()));

-- book_notes: خاصة 100%
drop policy if exists book_notes_all on public.book_notes;
create policy book_notes_all on public.book_notes for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and public.can_view_book(book_id));

-- reviews: كيبانو لكل واحد يقدر يشوف الكتاب
drop policy if exists reviews_select on public.reviews;
create policy reviews_select on public.reviews for select to authenticated
  using (public.can_view_book(book_id));
drop policy if exists reviews_insert on public.reviews;
create policy reviews_insert on public.reviews for insert to authenticated
  with check (user_id = (select auth.uid()) and public.can_view_book(book_id));
drop policy if exists reviews_update on public.reviews;
create policy reviews_update on public.reviews for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists reviews_delete on public.reviews;
create policy reviews_delete on public.reviews for delete to authenticated
  using (user_id = (select auth.uid()));


-- ---------------------------------------------------------------------
-- 5. تخزين الملفات (Storage)
-- ---------------------------------------------------------------------
-- pdfs: خاص، كل ملف كيتحمى بنفس قاعدة الكتاب. images: الأغلفة والصور الشخصية
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('pdfs',   'pdfs',   false, 52428800, array['application/pdf']),
  ('images', 'images', true,  5242880,  array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- كل مستخدم كيكتب غير ف الدوسي ديالو: {user_id}/...
drop policy if exists mk_pdfs_read on storage.objects;
create policy mk_pdfs_read on storage.objects for select to authenticated using (
  bucket_id = 'pdfs'
  and ((storage.foldername(name))[1] = (select auth.uid())::text or public.can_view_pdf(name))
);
drop policy if exists mk_own_insert on storage.objects;
create policy mk_own_insert on storage.objects for insert to authenticated with check (
  bucket_id in ('pdfs', 'images') and (storage.foldername(name))[1] = (select auth.uid())::text
);
drop policy if exists mk_own_update on storage.objects;
create policy mk_own_update on storage.objects for update to authenticated
  using (bucket_id in ('pdfs', 'images') and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id in ('pdfs', 'images') and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists mk_own_delete on storage.objects;
create policy mk_own_delete on storage.objects for delete to authenticated using (
  bucket_id in ('pdfs', 'images') and (storage.foldername(name))[1] = (select auth.uid())::text
);
drop policy if exists mk_images_read on storage.objects;
create policy mk_images_read on storage.objects for select to authenticated using (
  bucket_id = 'images' and (storage.foldername(name))[1] = (select auth.uid())::text
);


-- ---------------------------------------------------------------------
-- 6. الرسائل المباشرة (Realtime)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'friendships'
  ) then
    alter publication supabase_realtime add table public.friendships;
  end if;
end;
$$;

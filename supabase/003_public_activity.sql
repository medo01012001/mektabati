-- =====================================================================
--  مكتبتي — تحديث 003: نشاط القراءة عمومي + عدد الكتب ديال كل واحد
--  كيفاش: Supabase > SQL Editor > New snippet > نسخ هاد الملف كامل > Run
--  (يقدر يتعاود يتشغل بلا مشاكل)
-- =====================================================================

-- 1. "كيقرا دابا": كيبان لكاع المسجلين (ماشي غير الأصدقاء)
--    ولكن غير على الكتب اللي الشخص اللي كيشوف يقدر يشوفها (الكتب الخاصة 🔒 كتبقى مخفية)
--    واللي طفا "نبان ف القراء" كيبان النشاط ديالو غير لأصدقائه
drop policy if exists book_state_select on public.book_state;
create policy book_state_select on public.book_state for select to authenticated using (
  user_id = (select auth.uid())
  or (
    public.can_view_book(book_id)
    and (
      public.is_friend(user_id)
      or exists (select 1 from public.profiles p where p.id = book_state.user_id and p.discoverable)
    )
  )
);

-- 2. الأرقام ديال كل واحد: شحال من كتاب ف المكتبة، شحال رفع، شحال كيقرا، شحال كمل
--    (غير أرقام، بلا عناوين، باش الكتب الخاصة تبقى خاصة)
create or replace function public.get_user_stats(targets uuid[])
returns table (user_id uuid, library_count int, uploaded_count int, reading_count int, finished_count int)
language sql stable security definer set search_path = '' as $$
  select
    p.id,
    (select count(*)::int from public.book_state s where s.user_id = p.id),
    (select count(*)::int from public.books b where b.owner_id = p.id),
    (select count(*)::int from public.book_state s where s.user_id = p.id and s.progress > 0 and not s.is_read),
    (select count(*)::int from public.book_state s where s.user_id = p.id and s.is_read)
  from public.profiles p
  where p.id = any(targets)
    and (p.id = auth.uid() or p.discoverable or public.is_friend(p.id))
  limit 1000;
$$;

revoke execute on function public.get_user_stats(uuid[]) from public, anon;
grant execute on function public.get_user_stats(uuid[]) to authenticated;

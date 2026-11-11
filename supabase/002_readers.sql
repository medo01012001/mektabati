-- =====================================================================
--  مكتبتي — تحديث 002: لائحة القراء + طلب صداقة من البروفايل
--  كيفاش: Supabase > SQL Editor > New snippet > نسخ هاد الملف كامل > Run
--  (يقدر يتعاود يتشغل بلا مشاكل)
-- =====================================================================

-- 1. كل مستخدم يقدر يختار واش يبان ف "القراء" (افتراضيا: أيه)
alter table public.profiles add column if not exists discoverable boolean not null default true;
grant update (username, bio, avatar_path, discoverable) on public.profiles to authenticated;

-- 2. شكون يقدر يشوف البروفايل (الاسم، البايو، الصورة)
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (
  discoverable                                    -- ظاهر ف لائحة القراء
  or id = (select auth.uid())                     -- راسي
  or exists (                                     -- بيناتنا صداقة ولا طلب
    select 1 from public.friendships f
    where (f.requester_id = (select auth.uid()) and f.addressee_id = profiles.id)
       or (f.addressee_id = (select auth.uid()) and f.requester_id = profiles.id)
  )
  or exists (select 1 from public.books b where b.owner_id = profiles.id and b.visibility = 'public')
  or exists (select 1 from public.reviews r where r.user_id = profiles.id)
);

-- 3. طلب صداقة مباشرة من البروفايل (بلا كود)
--    كترجع: sent / accepted / already_sent / already_friends / not_found / self
create or replace function public.send_friend_request_to(target uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  existing public.friendships%rowtype;
begin
  if me is null then raise exception 'not authenticated'; end if;
  if target is null or not exists (select 1 from public.profiles p where p.id = target) then return 'not_found'; end if;
  if target = me then return 'self'; end if;

  select * into existing from public.friendships f
  where least(f.requester_id, f.addressee_id) = least(me, target)
    and greatest(f.requester_id, f.addressee_id) = greatest(me, target);

  if found then
    if existing.status = 'accepted' then return 'already_friends'; end if;
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

-- الطلب بالكود كيستعمل نفس المنطق
create or replace function public.send_friend_request(code text)
returns text language plpgsql security definer set search_path = '' as $$
declare target uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select p.id into target from public.profiles p where p.friend_code = upper(btrim(code));
  if target is null then return 'not_found'; end if;
  return public.send_friend_request_to(target);
end;
$$;

revoke execute on function public.send_friend_request_to(uuid) from public, anon;
grant execute on function public.send_friend_request_to(uuid) to authenticated;
revoke execute on function public.send_friend_request(text) from public, anon;
grant execute on function public.send_friend_request(text) to authenticated;

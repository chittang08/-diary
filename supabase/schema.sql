-- =====================================================================
-- 커플 다이어리 · Supabase 스키마
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여넣고 Run.
-- 여러 번 실행하지 말고 새 프로젝트에서 한 번만 실행하세요.
--
-- 구조
--   profiles        : 사용자 닉네임 (가입하면 자동 생성)
--   couples         : 커플 다이어리 한 권 (초대 코드로 두 사람 연결)
--   couple_members  : 다이어리에 속한 사람 (최대 2명, 한 사람은 한 커플만)
--   entries         : 날짜별 기록 (한 줄, 기분)
--   photos          : 사진 정보 (파일은 Storage 'photos' 버킷에 저장)
--   push_subscriptions : 알림 받을 기기 (Web Push 구독 정보)
--
-- 보안: 모든 테이블과 사진은 "같은 커플인 두 사람"만 읽고 쓸 수 있음 (RLS)
-- =====================================================================


-- ---------- 초대 코드 생성 ----------
-- 형식: 알파벳 2개(중복 허용) + 서로 다른 숫자 2개 + 서로 다른 알파벳 2개 (예: KK37BX)
-- (함수 본문은 실행할 때 해석되므로 couples 테이블보다 먼저 만들어도 됨)
create or replace function public.generate_invite_code()
returns text
language plpgsql volatile set search_path = public
as $$
declare
  letters constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  d1 int; d2 int; l1 int; l2 int;
  code text;
begin
  loop
    d1 := floor(random() * 10)::int;
    d2 := floor(random() * 9)::int;  if d2 >= d1 then d2 := d2 + 1; end if;
    l1 := floor(random() * 26)::int;
    l2 := floor(random() * 25)::int; if l2 >= l1 then l2 := l2 + 1; end if;
    code := substr(letters, floor(random() * 26)::int + 1, 1)
         || substr(letters, floor(random() * 26)::int + 1, 1)
         || d1::text || d2::text
         || substr(letters, l1 + 1, 1)
         || substr(letters, l2 + 1, 1);
    exit when not exists (select 1 from public.couples where invite_code = code);
  end loop;
  return code;
end
$$;


-- ---------- 테이블 ----------

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nickname    text,
  created_at  timestamptz not null default now()
);

create table public.couples (
  id           uuid primary key default gen_random_uuid(),
  invite_code  text not null unique default public.generate_invite_code(),
  started_on   date,                                   -- 사귄 날 (D-day 계산용)
  created_at   timestamptz not null default now()
);

create table public.couple_members (
  couple_id  uuid not null references public.couples(id) on delete cascade,
  user_id    uuid not null unique references auth.users(id) on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (couple_id, user_id)
);

create table public.entries (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  author_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  entry_date  date not null default current_date,
  content     text not null default '',
  mood        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index entries_couple_date_idx on public.entries (couple_id, entry_date desc);

create table public.photos (
  id            uuid primary key default gen_random_uuid(),
  couple_id     uuid not null references public.couples(id) on delete cascade,
  entry_id      uuid references public.entries(id) on delete set null,
  uploader_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  storage_path  text not null unique,                  -- '{couple_id}/{파일이름}'
  caption       text,
  taken_on      date not null default current_date,
  created_at    timestamptz not null default now()
);
create index photos_couple_date_idx on public.photos (couple_id, taken_on desc);

create table public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);


-- ---------- 도우미 함수 ----------

-- 지금 로그인한 사람의 커플 id (없으면 null)
create or replace function public.my_couple_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select couple_id from public.couple_members where user_id = auth.uid()
$$;

-- 가입하면 profiles 자동 생성
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, nickname)
  values (new.id, coalesce(new.raw_user_meta_data->>'nickname', split_part(new.email, '@', 1)));
  return new;
end
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- entries 수정 시간 자동 갱신
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end
$$;

create trigger entries_touch_updated_at
  before update on public.entries
  for each row execute function public.touch_updated_at();


-- ---------- 커플 만들기 / 초대 코드로 연결 ----------

-- 새 커플 다이어리 만들기 → 초대 코드가 담긴 couples 행을 돌려줌
create or replace function public.create_couple()
returns public.couples
language plpgsql security definer set search_path = public
as $$
declare c public.couples;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요해요';
  end if;
  if exists (select 1 from public.couple_members where user_id = auth.uid()) then
    raise exception '이미 커플 다이어리에 연결되어 있어요';
  end if;

  insert into public.couples default values returning * into c;
  insert into public.couple_members (couple_id, user_id) values (c.id, auth.uid());
  return c;
end
$$;

-- 상대가 준 초대 코드로 연결
create or replace function public.join_couple(code text)
returns public.couples
language plpgsql security definer set search_path = public
as $$
declare c public.couples;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요해요';
  end if;
  if exists (select 1 from public.couple_members where user_id = auth.uid()) then
    raise exception '이미 커플 다이어리에 연결되어 있어요';
  end if;

  select * into c from public.couples where invite_code = upper(trim(code)) for update;
  if not found then
    raise exception '초대 코드를 찾을 수 없어요';
  end if;
  if (select count(*) from public.couple_members where couple_id = c.id) >= 2 then
    raise exception '이미 두 사람이 연결된 다이어리예요';
  end if;

  insert into public.couple_members (couple_id, user_id) values (c.id, auth.uid());
  return c;
end
$$;

-- 함수는 기본으로 public(=누구나)에게 열려 있으므로, 로그인한 사람만 부를 수 있게 좁힘
revoke execute on function public.create_couple() from public, anon;
revoke execute on function public.join_couple(text) from public, anon;
grant execute on function public.create_couple() to authenticated;
grant execute on function public.join_couple(text) to authenticated;


-- ---------- 접근 권한 (RLS) ----------

alter table public.profiles       enable row level security;
alter table public.couples        enable row level security;
alter table public.couple_members enable row level security;
alter table public.entries        enable row level security;
alter table public.photos         enable row level security;
alter table public.push_subscriptions enable row level security;

-- profiles: 나와 내 짝꿍 것만 보기, 내 것만 수정
create policy "profiles: 나와 짝꿍 보기" on public.profiles
  for select to authenticated
  using (id = auth.uid()
         or id in (select user_id from public.couple_members where couple_id = public.my_couple_id()));
create policy "profiles: 내 것 수정" on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- couples: 내 커플만 보기/수정 (사귄 날 등). 생성·연결은 위 함수로만.
create policy "couples: 내 커플 보기" on public.couples
  for select to authenticated using (id = public.my_couple_id());
create policy "couples: 내 커플 수정" on public.couples
  for update to authenticated
  using (id = public.my_couple_id()) with check (id = public.my_couple_id());

-- couple_members: 내 커플 구성원만 보기
create policy "members: 내 커플 보기" on public.couple_members
  for select to authenticated using (couple_id = public.my_couple_id());

-- entries: 둘 다 보기, 쓴 사람만 수정·삭제
create policy "entries: 커플이 보기" on public.entries
  for select to authenticated using (couple_id = public.my_couple_id());
create policy "entries: 내가 쓰기" on public.entries
  for insert to authenticated
  with check (couple_id = public.my_couple_id() and author_id = auth.uid());
create policy "entries: 내 글 수정" on public.entries
  for update to authenticated
  using (author_id = auth.uid() and couple_id = public.my_couple_id())
  with check (author_id = auth.uid() and couple_id = public.my_couple_id());
create policy "entries: 내 글 삭제" on public.entries
  for delete to authenticated
  using (author_id = auth.uid() and couple_id = public.my_couple_id());

-- photos: 둘 다 보기, 올린 사람만 수정·삭제
create policy "photos: 커플이 보기" on public.photos
  for select to authenticated using (couple_id = public.my_couple_id());
create policy "photos: 내가 올리기" on public.photos
  for insert to authenticated
  with check (couple_id = public.my_couple_id() and uploader_id = auth.uid());
create policy "photos: 내 사진 수정" on public.photos
  for update to authenticated
  using (uploader_id = auth.uid() and couple_id = public.my_couple_id())
  with check (uploader_id = auth.uid() and couple_id = public.my_couple_id());
create policy "photos: 내 사진 삭제" on public.photos
  for delete to authenticated
  using (uploader_id = auth.uid() and couple_id = public.my_couple_id());


-- push_subscriptions: 내 기기만 보기/등록/수정/삭제 (짝꿍에게 보내는 건 Edge Function 이 service role 로 처리)
create policy "push: 내 기기 보기" on public.push_subscriptions
  for select to authenticated using (user_id = auth.uid());
create policy "push: 내 기기 등록" on public.push_subscriptions
  for insert to authenticated with check (user_id = auth.uid());
create policy "push: 내 기기 수정" on public.push_subscriptions
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "push: 내 기기 삭제" on public.push_subscriptions
  for delete to authenticated using (user_id = auth.uid());


-- ---------- 실시간 동기화 (Realtime) ----------
-- 짝꿍의 기록 변경(entries)과 초대 코드 연결(couple_members)을 앱이 실시간으로 받도록 등록.
-- 받는 쪽에서도 RLS가 적용되므로 같은 커플의 변경만 전달됨.

alter publication supabase_realtime add table public.entries, public.couple_members;


-- ---------- 사진 저장소 (Storage) ----------
-- 비공개 버킷. 파일 경로 첫 폴더가 커플 id 인 것만 그 커플이 접근 가능.

insert into storage.buckets (id, name, public)
values ('photos', 'photos', false)
on conflict (id) do nothing;

create policy "storage: 커플 사진 보기" on storage.objects
  for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_couple_id()::text);
create policy "storage: 커플 사진 올리기" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_couple_id()::text);
create policy "storage: 커플 사진 삭제" on storage.objects
  for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_couple_id()::text);

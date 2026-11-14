-- =====================================================================
-- 커플 다이어리 · Supabase 스키마
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여넣고 Run.
-- 여러 번 실행하지 말고 새 프로젝트에서 한 번만 실행하세요.
--
-- 구조
--   profiles              : 사용자 닉네임 (가입하면 자동 생성)
--   couples               : 커플 다이어리 한 권 (초대 코드로 두 사람 연결)
--   couple_members        : 다이어리에 속한 사람 (최대 2명, 한 사람은 한 커플만)
--   entries               : 하루 한 줄 기록 + 기분 (한 사람당 하루 하나)
--   routines              : 둘이 같이 정한 약속(루틴) 목록
--   routine_checks        : 날짜별로 누가 어떤 약속을 지켰는지
--   photos                : 사진 정보 (파일은 Storage 'photos' 버킷에 저장). 날짜 사진 또는 앨범 사진
--   albums                : 사진첩의 앨범(작은 책) 한 권
--   push_subscriptions    : 알림 받을 기기 (Web Push 구독 정보)
--   couple_join_attempts  : 초대 코드 틀린 기록 (대입 공격 막기용, 아무도 직접 못 봄)
--
-- 보안
--   - 모든 테이블과 사진은 "같은 커플인 두 사람"만 읽고 쓸 수 있음 (RLS)
--   - 로그인 안 한 사람(anon)은 테이블·함수에 아예 접근 권한이 없음
--   - 수정은 바꿔도 되는 칸만 열어 둠 (예: 커플은 사귄 날만)
--   - 초대 코드는 15분 안에 5번 틀리면 잠시 잠김, 둘이 연결되면 바로 무효화(null)
-- =====================================================================


-- ---------- 테이블 ----------

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nickname    text check (nickname is null or char_length(nickname) between 1 and 20),
  created_at  timestamptz not null default now()
);

create table public.couples (
  id           uuid primary key default gen_random_uuid(),
  invite_code  text unique,                            -- 기본값은 아래 generate_invite_code() 에서 지정. 둘이 연결되면 null (무효화)
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
  content     text not null default '' check (char_length(content) <= 2000),
  mood        text check (mood is null or char_length(mood) <= 20),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index entries_couple_date_idx on public.entries (couple_id, entry_date desc);
create unique index entries_one_per_day on public.entries (couple_id, author_id, entry_date);

create table public.routines (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 60),
  sort        int  not null default 0,
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,   -- 만든 사람이 탈퇴해도 약속은 남김
  created_at  timestamptz not null default now()
);
create index routines_couple_idx on public.routines (couple_id, sort, created_at);

create table public.routine_checks (
  routine_id  uuid not null references public.routines(id) on delete cascade,
  couple_id   uuid not null references public.couples(id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  check_date  date not null,
  created_at  timestamptz not null default now(),
  primary key (routine_id, user_id, check_date)    -- 한 사람이 하루에 한 번만 체크
);
create index routine_checks_couple_date_idx on public.routine_checks (couple_id, check_date desc);

create table public.albums (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  title       text not null check (char_length(trim(title)) between 1 and 30),
  cover       text not null default 'rose' check (cover in ('rose','cherry','coral','butter','sage','mint','sky','navy','lilac','pink','cocoa','plum')),
  sort        int  not null default 0,
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index albums_couple_idx on public.albums (couple_id, sort, created_at);

create table public.photos (
  id            uuid primary key default gen_random_uuid(),
  couple_id     uuid not null references public.couples(id) on delete cascade,
  entry_id      uuid references public.entries(id) on delete set null,
  uploader_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  storage_path  text not null unique check (char_length(storage_path) <= 300),   -- '{couple_id}/{파일이름}'
  caption       text check (caption is null or char_length(caption) <= 200),
  taken_on      date not null default current_date,
  -- 앨범에 붙인 사진이면: 어느 앨범에, 어디에(페이지 너비 기준 비율), 몇 도 기울여서
  album_id      uuid references public.albums(id) on delete cascade,
  pos_x         real check (pos_x is null or (pos_x >= 0 and pos_x <= 1)),
  pos_y         real check (pos_y is null or (pos_y >= 0 and pos_y <= 20)),
  rot           real not null default 0 check (rot between -45 and 45),
  created_at    timestamptz not null default now()
);
create index photos_couple_date_idx on public.photos (couple_id, taken_on desc);
create index photos_album_idx on public.photos (album_id) where album_id is not null;

create table public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  endpoint    text not null unique check (endpoint like 'https://%' and char_length(endpoint) <= 1000),
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now(),
  check (char_length(p256dh) <= 200 and char_length(auth) <= 100)
);

create table public.couple_join_attempts (
  user_id       uuid not null references auth.users(id) on delete cascade,
  attempted_at  timestamptz not null default now()
);
create index couple_join_attempts_idx on public.couple_join_attempts (user_id, attempted_at desc);


-- ---------- 도우미 함수 ----------

-- 지금 로그인한 사람의 커플 id (없으면 null)
create or replace function public.my_couple_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select couple_id from public.couple_members where user_id = auth.uid()
$$;

-- 가입하면 profiles 자동 생성 (닉네임은 20자까지, 없으면 이메일 앞부분)
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, nickname)
  values (new.id, coalesce(left(nullif(trim(new.raw_user_meta_data->>'nickname'), ''), 20),
                           left(split_part(new.email, '@', 1), 20)));
  return new;
end
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- entries 수정 시간 자동 갱신
create or replace function public.touch_updated_at()
returns trigger
language plpgsql set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end
$$;

create trigger entries_touch_updated_at
  before update on public.entries
  for each row execute function public.touch_updated_at();

-- 초대 코드: 알파벳 2개(중복 허용) + 서로 다른 숫자 2개 + 서로 다른 알파벳 2개 (예: KK37BX)
-- 예측할 수 없도록 암호학적 난수(gen_random_bytes) 사용
create or replace function public.generate_invite_code()
returns text
language plpgsql volatile set search_path = public
as $$
declare
  letters constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  b bytea; d1 int; d2 int; l1 int; l2 int; code text;
begin
  loop
    b  := extensions.gen_random_bytes(18);
    d1 := ((get_byte(b,0)<<16) | (get_byte(b,1)<<8) | get_byte(b,2)) % 10;
    d2 := ((get_byte(b,3)<<16) | (get_byte(b,4)<<8) | get_byte(b,5)) % 9;  if d2 >= d1 then d2 := d2 + 1; end if;
    l1 := ((get_byte(b,6)<<16) | (get_byte(b,7)<<8) | get_byte(b,8)) % 26;
    l2 := ((get_byte(b,9)<<16) | (get_byte(b,10)<<8) | get_byte(b,11)) % 25; if l2 >= l1 then l2 := l2 + 1; end if;
    code := substr(letters, ((get_byte(b,12)<<16) | (get_byte(b,13)<<8) | get_byte(b,14)) % 26 + 1, 1)
         || substr(letters, ((get_byte(b,15)<<16) | (get_byte(b,16)<<8) | get_byte(b,17)) % 26 + 1, 1)
         || d1::text || d2::text
         || substr(letters, l1 + 1, 1)
         || substr(letters, l2 + 1, 1);
    exit when not exists (select 1 from public.couples where invite_code = code);
  end loop;
  return code;
end
$$;

alter table public.couples alter column invite_code set default public.generate_invite_code();

-- 히트맵용: 날짜·사람별 체크 개수 (RLS 그대로 적용되도록 security invoker)
create or replace function public.couple_check_days(since date)
returns table (check_date date, user_id uuid, n int)
language sql stable security invoker set search_path = public
as $$
  select c.check_date, c.user_id, count(*)::int
  from public.routine_checks c
  where c.couple_id = public.my_couple_id() and c.check_date >= since
  group by c.check_date, c.user_id
$$;


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

-- 상대가 준 초대 코드로 연결. 코드를 못 찾으면 null (틀린 횟수 기록), 15분에 5번 틀리면 잠금.
-- 연결되는 순간 초대 코드는 지워져서(null) 다시 쓸 수 없음
create or replace function public.join_couple(code text)
returns public.couples
language plpgsql security definer set search_path = public
as $$
declare c public.couples; tries int;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요해요';
  end if;
  if exists (select 1 from public.couple_members where user_id = auth.uid()) then
    raise exception '이미 커플 다이어리에 연결되어 있어요';
  end if;

  select count(*) into tries from public.couple_join_attempts
  where user_id = auth.uid() and attempted_at > now() - interval '15 minutes';
  if tries >= 5 then
    raise exception '초대 코드를 너무 많이 틀렸어요. 15분 뒤에 다시 시도해 주세요.';
  end if;

  select * into c from public.couples
  where invite_code = upper(trim(left(coalesce(code, ''), 12))) for update;
  if not found then
    -- 에러를 내면 기록까지 취소되므로, 틀린 횟수를 남기고 빈 값으로 돌려줌
    insert into public.couple_join_attempts (user_id) values (auth.uid());
    return null;
  end if;
  if (select count(*) from public.couple_members where couple_id = c.id) >= 2 then
    raise exception '이미 두 사람이 연결된 다이어리예요';
  end if;

  insert into public.couple_members (couple_id, user_id) values (c.id, auth.uid());
  -- 둘이 연결됐으니 초대 코드는 무효화
  update public.couples set invite_code = null where id = c.id returning * into c;
  delete from public.couple_join_attempts where user_id = auth.uid();
  return c;
end
$$;


-- 탈퇴: 내 계정과 내 기록·사진 정보가 지워짐 (연결된 표는 cascade).
-- 짝꿍이 남으면 다이어리는 유지되고 새 초대 코드를 줌. 혼자였다면 다이어리도 지움.
-- (사진 파일 자체는 앱이 Storage API 로 먼저 지움)
create or replace function public.delete_my_account()
returns void
language plpgsql security definer set search_path = public
as $$
declare uid uuid := auth.uid(); cid uuid; remaining int;
begin
  if uid is null then
    raise exception '로그인이 필요해요';
  end if;
  if not exists (select 1 from auth.users where id = uid) then
    raise exception '이미 탈퇴한 계정이에요';
  end if;
  select couple_id into cid from public.couple_members where user_id = uid;

  delete from auth.users where id = uid;

  if cid is not null then
    select count(*) into remaining from public.couple_members where couple_id = cid;
    if remaining = 0 then
      delete from public.couples where id = cid;
    else
      update public.couples set invite_code = public.generate_invite_code()
      where id = cid and invite_code is null;
    end if;
  end if;
end
$$;


-- ---------- 권한 (누가 무엇을 할 수 있나) ----------

-- 로그인 안 한 사람(anon)은 테이블에 아예 손 못 댐. 로그인한 사람도 TRUNCATE 등 위험 권한 제거
revoke all on all tables in schema public from anon;
revoke truncate, trigger, references on all tables in schema public from authenticated;
alter default privileges in schema public revoke all on tables from anon;

-- 커플·멤버·프로필의 생성·삭제는 정해진 길(위 함수, 가입 트리거)로만
revoke insert, delete on public.couples, public.couple_members, public.profiles from authenticated;
revoke update on public.couple_members from authenticated;
revoke all on public.couple_join_attempts from anon, authenticated;

-- 수정은 바꿔도 되는 칸만
revoke update on public.couples, public.profiles, public.entries, public.photos, public.routines, public.push_subscriptions, public.albums from authenticated;
grant update (started_on)                  on public.couples            to authenticated;
grant update (nickname)                    on public.profiles           to authenticated;
grant update (content, mood)               on public.entries            to authenticated;
grant update (caption, taken_on, entry_id, pos_x, pos_y, rot) on public.photos to authenticated;
grant update (title, cover, sort)          on public.albums             to authenticated;
grant update (name, sort)                  on public.routines           to authenticated;
grant update (p256dh, auth)                on public.push_subscriptions to authenticated;

-- 함수는 기본으로 누구나 부를 수 있으므로 필요한 것만 로그인한 사람에게 열어 줌
revoke execute on function public.create_couple()          from public, anon;
revoke execute on function public.join_couple(text)        from public, anon;
revoke execute on function public.my_couple_id()           from public, anon;
revoke execute on function public.couple_check_days(date)  from public, anon;
revoke execute on function public.delete_my_account()      from public, anon;
grant  execute on function public.delete_my_account()      to authenticated;
grant  execute on function public.create_couple()          to authenticated;
grant  execute on function public.join_couple(text)        to authenticated;
grant  execute on function public.my_couple_id()           to authenticated;   -- RLS 규칙 안에서 쓰임
grant  execute on function public.couple_check_days(date)  to authenticated;
-- 트리거·기본값 전용 함수는 직접 못 부르게
revoke execute on function public.handle_new_user()        from public, anon, authenticated;
revoke execute on function public.touch_updated_at()       from public, anon, authenticated;
revoke execute on function public.generate_invite_code()   from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;


-- ---------- 접근 규칙 (RLS) ----------

alter table public.profiles             enable row level security;
alter table public.couples              enable row level security;
alter table public.couple_members       enable row level security;
alter table public.entries              enable row level security;
alter table public.photos               enable row level security;
alter table public.routines             enable row level security;
alter table public.routine_checks       enable row level security;
alter table public.push_subscriptions   enable row level security;
alter table public.albums               enable row level security;
alter table public.couple_join_attempts enable row level security;   -- 규칙 없음 = 함수 말고는 아무도 못 봄

-- profiles: 나와 내 짝꿍 것만 보기, 내 것만 수정
create policy "profiles: 나와 짝꿍 보기" on public.profiles
  for select to authenticated
  using (id = auth.uid()
         or id in (select user_id from public.couple_members where couple_id = public.my_couple_id()));
create policy "profiles: 내 것 수정" on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- couples: 내 커플만 보기/수정 (사귄 날). 생성·연결은 위 함수로만.
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

-- routines: 둘이 같이 정한 약속이라 둘 다 추가·수정·삭제
create policy "routines: 커플이 보기" on public.routines
  for select to authenticated using (couple_id = public.my_couple_id());
create policy "routines: 커플이 추가" on public.routines
  for insert to authenticated
  with check (couple_id = public.my_couple_id() and created_by = auth.uid());
create policy "routines: 커플이 수정" on public.routines
  for update to authenticated
  using (couple_id = public.my_couple_id()) with check (couple_id = public.my_couple_id());
create policy "routines: 커플이 삭제" on public.routines
  for delete to authenticated using (couple_id = public.my_couple_id());

-- routine_checks: 둘 다 보기, 체크는 각자 자기 것만
create policy "checks: 커플이 보기" on public.routine_checks
  for select to authenticated using (couple_id = public.my_couple_id());
create policy "checks: 내 체크 추가" on public.routine_checks
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and couple_id = public.my_couple_id()
    and exists (select 1 from public.routines r where r.id = routine_id and r.couple_id = public.my_couple_id())
  );
create policy "checks: 내 체크 취소" on public.routine_checks
  for delete to authenticated
  using (user_id = auth.uid() and couple_id = public.my_couple_id());

-- albums: 둘이 같이 쓰는 사진첩이라 둘 다 만들고 고치고 지움
create policy "albums: 커플이 보기" on public.albums
  for select to authenticated using (couple_id = public.my_couple_id());
create policy "albums: 커플이 만들기" on public.albums
  for insert to authenticated
  with check (couple_id = public.my_couple_id() and created_by = auth.uid());
create policy "albums: 커플이 수정" on public.albums
  for update to authenticated
  using (couple_id = public.my_couple_id()) with check (couple_id = public.my_couple_id());
create policy "albums: 커플이 삭제" on public.albums
  for delete to authenticated using (couple_id = public.my_couple_id());

-- photos: 둘 다 보기, 올린 사람만 수정·삭제. 경로는 우리 커플 폴더만, 연결 기록·앨범도 우리 커플 것만
create policy "photos: 커플이 보기" on public.photos
  for select to authenticated using (couple_id = public.my_couple_id());
create policy "photos: 내가 올리기" on public.photos
  for insert to authenticated
  with check (
    couple_id = public.my_couple_id() and uploader_id = auth.uid()
    and storage_path like public.my_couple_id()::text || '/%'
    and (entry_id is null or exists (select 1 from public.entries e where e.id = entry_id and e.couple_id = public.my_couple_id()))
    and (album_id is null or exists (select 1 from public.albums a where a.id = album_id and a.couple_id = public.my_couple_id()))
  );
create policy "photos: 내 사진 수정" on public.photos
  for update to authenticated
  using (uploader_id = auth.uid() and couple_id = public.my_couple_id())
  with check (
    uploader_id = auth.uid() and couple_id = public.my_couple_id()
    and (entry_id is null or exists (select 1 from public.entries e where e.id = entry_id and e.couple_id = public.my_couple_id()))
  );
create policy "photos: 내 사진 삭제" on public.photos
  for delete to authenticated
  using (uploader_id = auth.uid() and couple_id = public.my_couple_id());

-- push_subscriptions: 내 기기만
create policy "push: 내 기기 보기" on public.push_subscriptions
  for select to authenticated using (user_id = auth.uid());
create policy "push: 내 기기 등록" on public.push_subscriptions
  for insert to authenticated with check (user_id = auth.uid());
create policy "push: 내 기기 수정" on public.push_subscriptions
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "push: 내 기기 삭제" on public.push_subscriptions
  for delete to authenticated using (user_id = auth.uid());


-- ---------- 사진 저장소 (Storage) ----------
-- 비공개 버킷, 10MB 이하 이미지 파일만. 파일 경로 첫 폴더가 커플 id 인 것만 그 커플이 접근 가능.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','image/heif','image/gif'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy "storage: 커플 사진 보기" on storage.objects
  for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_couple_id()::text);
create policy "storage: 커플 사진 올리기" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_couple_id()::text);
create policy "storage: 내 사진 파일 삭제" on storage.objects   -- 파일 삭제는 올린 사람 본인만
  for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = public.my_couple_id()::text and owner = auth.uid());


-- ---------- 실시간 반영 (Realtime) ----------
-- 테이블 변경 알림을 켬. 받는 내용은 위 RLS 규칙대로 같은 커플 것만 전달됨.
-- 이미 등록된 테이블은 건너뛰므로 여러 번 실행해도 안전.

do $$
declare t text;
begin
  foreach t in array array['couple_members', 'entries', 'photos'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end
$$;

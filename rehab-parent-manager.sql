-- رحاب القرآن: ولي الأمر + سلامة توزيع الطلاب على الحلقات + المراسلة والإنجازات
-- شغّله مرة واحدة في Supabase → SQL Editor (آمن لإعادة التشغيل). يفترض وجود جداول rq_* الحالية.

-- 1) سجل نقل الطلاب بين الحلقات
create table if not exists public.rq_student_moves (
  id bigint generated always as identity primary key,
  student_id uuid not null,
  from_circle uuid,
  to_circle uuid,
  by_user uuid default auth.uid(),
  at timestamptz not null default now()
);
alter table public.rq_student_moves enable row level security;

-- 2) رسائل أولياء الأمور والمحفّظين
create table if not exists public.rq_messages (
  id bigint generated always as identity primary key,
  center_id uuid,
  student_id uuid not null,
  circle_id uuid,
  direction text not null check (direction in ('parent','sheikh')),
  body text not null check (char_length(body) between 1 and 600),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists rq_messages_student_idx on public.rq_messages(student_id, created_at desc);
alter table public.rq_messages enable row level security;

-- 3) الإنجازات والشهادات
create table if not exists public.rq_achievements (
  id bigint generated always as identity primary key,
  center_id uuid,
  student_id uuid not null,
  kind text not null default 'certificate',
  title text not null,
  detail text,
  awarded_on date not null default current_date
);
create index if not exists rq_ach_student_idx on public.rq_achievements(student_id, awarded_on desc);
alter table public.rq_achievements enable row level security;

-- 4) مركز المستخدم الحالي (للسياسات)
create or replace function public.rq_my_center() returns uuid
language sql stable security definer set search_path = public as
$$ select center_id from public.rq_profiles where user_id = auth.uid() limit 1 $$;

do $$ begin
  if not exists (select 1 from pg_policies where tablename='rq_messages' and policyname='rq_messages_staff') then
    create policy rq_messages_staff on public.rq_messages for all to authenticated
      using (center_id = public.rq_my_center()) with check (center_id = public.rq_my_center());
  end if;
  if not exists (select 1 from pg_policies where tablename='rq_achievements' and policyname='rq_ach_staff') then
    create policy rq_ach_staff on public.rq_achievements for all to authenticated
      using (center_id = public.rq_my_center()) with check (center_id = public.rq_my_center());
  end if;
  if not exists (select 1 from pg_policies where tablename='rq_student_moves' and policyname='rq_moves_read') then
    create policy rq_moves_read on public.rq_student_moves for select to authenticated
      using (exists (select 1 from public.rq_students s where s.id = student_id and s.center_id = public.rq_my_center()));
  end if;
end $$;

-- 5) حماية الاختلاط: الطالب لا يُسند إلا لحلقة من نفس مركزه، والسعة تُحترم، وكل نقل يُسجَّل
create or replace function public.rq_students_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare c record; n int;
begin
  if new.circle_id is not null and (tg_op = 'INSERT' or new.circle_id is distinct from old.circle_id) then
    select id, center_id, capacity, name into c from public.rq_circles where id = new.circle_id;
    if not found then raise exception 'الحلقة غير موجودة'; end if;
    if c.center_id is distinct from new.center_id then raise exception 'لا يمكن إسناد طالب إلى حلقة من مركز آخر'; end if;
    if coalesce(c.capacity,0) > 0 then
      select count(*) into n from public.rq_students where circle_id = new.circle_id and id is distinct from new.id;
      if n >= c.capacity then raise exception 'حلقة «%» ممتلئة', c.name; end if;
    end if;
  end if;
  if tg_op = 'UPDATE' and new.circle_id is distinct from old.circle_id then
    insert into public.rq_student_moves(student_id, from_circle, to_circle) values (new.id, old.circle_id, new.circle_id);
  end if;
  return new;
end $$;
drop trigger if exists rq_students_guard_trg on public.rq_students;
create trigger rq_students_guard_trg before insert or update of circle_id on public.rq_students
  for each row execute function public.rq_students_guard();

-- التقرير الجديد يرث حلقة الطالب الحالية دائماً (يمنع تسجيله في حلقة خاطئة)
create or replace function public.rq_reports_circle() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    select circle_id into new.circle_id from public.rq_students where id = new.student_id;
  end if;
  return new;
end $$;
drop trigger if exists rq_reports_circle_trg on public.rq_reports;
create trigger rq_reports_circle_trg before insert on public.rq_reports
  for each row execute function public.rq_reports_circle();

-- نقل طالب (يستدعيه المدير من التطبيق)
create or replace function public.rq_move_student(p_student uuid, p_circle uuid) returns void
language plpgsql security invoker set search_path = public as $$
begin
  update public.rq_students set circle_id = p_circle where id = p_student;
  if not found then raise exception 'لا صلاحية أو الطالب غير موجود'; end if;
end $$;
grant execute on function public.rq_move_student(uuid, uuid) to authenticated;

-- 6) بوابة ولي الأمر: تُثري ناتج rq_student_portal بالحضور والتنبيهات والرسائل والإنجازات
create or replace function public.rq_parent_portal(p_national_id text, p_today date default current_date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  nid text := regexp_replace(coalesce(p_national_id,''), '\s', '', 'g');
  base jsonb; sid uuid; att jsonb; alr jsonb := '[]'::jsonb; msg jsonb; ach jsonb; run int := 0; r record; pct numeric;
begin
  base := public.rq_student_portal(nid, p_today);
  select id into sid from public.rq_students where national_id = nid limit 1;
  if sid is null or base is null or jsonb_array_length(coalesce(base->'students','[]'::jsonb)) = 0 then return base; end if;

  select coalesce(jsonb_agg(jsonb_build_object('date', report_date, 'status', status) order by report_date desc), '[]'::jsonb)
    into att from public.rq_reports where student_id = sid and report_date > p_today - 30 and report_date <= p_today;

  for r in select status from public.rq_reports where student_id = sid and report_date <= p_today order by report_date desc limit 14 loop
    if r.status = 'غائب' then run := run + 1; elsif r.status = 'غائب بعذر' then continue; else exit; end if;
  end loop;
  if run >= 2 then alr := alr || jsonb_build_array(jsonb_build_object('level','bad','text','غاب ابنك '||run||' أيام متتالية، يرجى التواصل مع المحفّظ.')); end if;

  select round(100.0 * count(*) filter (where status in ('حافظ','مقصر')) / nullif(count(*) filter (where status in ('حافظ','مقصر','غائب')),0))
    into pct from public.rq_reports where student_id = sid and report_date >= date_trunc('month', p_today)::date and report_date <= p_today;
  if pct is not null and pct < 60 then alr := alr || jsonb_build_array(jsonb_build_object('level','bad','text','نسبة حضور هذا الشهر '||pct||'٪ وهي أقل من المطلوب.')); end if;
  if not exists (select 1 from public.rq_reports where student_id = sid and report_date = p_today) then
    alr := alr || jsonb_build_array(jsonb_build_object('level','warn','text','لم يُسجَّل تقرير اليوم بعد.'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('direction', direction, 'body', body, 'at', created_at) order by created_at desc), '[]'::jsonb)
    into msg from (select * from public.rq_messages where student_id = sid order by created_at desc limit 40) m;
  select coalesce(jsonb_agg(jsonb_build_object('title', title, 'detail', detail, 'kind', kind, 'awarded_on', awarded_on) order by awarded_on desc), '[]'::jsonb)
    into ach from public.rq_achievements where student_id = sid;

  return jsonb_set(base, '{students,0}', (base->'students'->0) || jsonb_build_object('attendance', att, 'alerts', alr, 'messages', msg, 'achievements', ach));
end $$;
grant execute on function public.rq_parent_portal(text, date) to anon, authenticated;

-- إرسال رسالة ولي الأمر (بحد أقصى ١٠ رسائل يومياً لكل طالب)
create or replace function public.rq_parent_send(p_national_id text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare nid text := regexp_replace(coalesce(p_national_id,''), '\s', '', 'g'); s record; b text := left(btrim(coalesce(p_body,'')), 600);
begin
  if b = '' then raise exception 'الرسالة فارغة'; end if;
  select id, center_id, circle_id into s from public.rq_students where national_id = nid limit 1;
  if not found then raise exception 'رقم الهوية غير مسجّل'; end if;
  if (select count(*) from public.rq_messages where student_id = s.id and direction = 'parent' and created_at > now() - interval '1 day') >= 10 then
    raise exception 'بلغت الحد اليومي من الرسائل'; end if;
  insert into public.rq_messages(center_id, student_id, circle_id, direction, body) values (s.center_id, s.id, s.circle_id, 'parent', b);
end $$;
grant execute on function public.rq_parent_send(text, text) to anon, authenticated;

notify pgrst, 'reload schema';

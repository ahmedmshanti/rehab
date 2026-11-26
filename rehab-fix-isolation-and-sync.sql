-- رحاب القرآن — إصلاح: (1) المحفّظ يرى طلاب حلقاته فقط  (2) ظهور تقرير اليوم والإنجاز عند ولي الأمر فوراً
-- شغّله مرة واحدة في Supabase → SQL Editor (بعد rehab-parent-manager.sql). آمن لإعادة التشغيل.

-- ───────── 1) دوال مساعدة (بصلاحية المالك حتى لا تتأثر بالسياسات) ─────────
create or replace function public.rq_viewer_role() returns text
language sql stable security definer set search_path = public as
$$ select role::text from public.rq_profiles where user_id = auth.uid() limit 1 $$;

create or replace function public.rq_my_circle_ids() returns setof uuid
language sql stable security definer set search_path = public as
$$ select id from public.rq_circles where sheikh_id = auth.uid() $$;

create or replace function public.rq_student_in_my_circles(p_student uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.rq_students s
                  where s.id = p_student and s.circle_id in (select public.rq_my_circle_ids())) $$;

-- ───────── 2) سياسات «مقيِّدة»: تُضاف فوق السياسات الحالية ولا تحذفها ─────────
-- المحفّظ (role = sheikh) لا يرى ولا يكتب إلا ما يخص حلقاته. المدير وغيره لا يتأثرون.
drop policy if exists rq_students_sheikh_scope on public.rq_students;
create policy rq_students_sheikh_scope on public.rq_students
  as restrictive for select to authenticated
  using (public.rq_viewer_role() is distinct from 'sheikh' or circle_id in (select public.rq_my_circle_ids()));

drop policy if exists rq_reports_sheikh_scope on public.rq_reports;
create policy rq_reports_sheikh_scope on public.rq_reports
  as restrictive for all to authenticated
  using      (public.rq_viewer_role() is distinct from 'sheikh' or public.rq_student_in_my_circles(student_id))
  with check (public.rq_viewer_role() is distinct from 'sheikh' or public.rq_student_in_my_circles(student_id));

drop policy if exists rq_messages_sheikh_scope on public.rq_messages;
create policy rq_messages_sheikh_scope on public.rq_messages
  as restrictive for all to authenticated
  using      (public.rq_viewer_role() is distinct from 'sheikh' or public.rq_student_in_my_circles(student_id))
  with check (public.rq_viewer_role() is distinct from 'sheikh' or public.rq_student_in_my_circles(student_id));

drop policy if exists rq_ach_sheikh_scope on public.rq_achievements;
create policy rq_ach_sheikh_scope on public.rq_achievements
  as restrictive for all to authenticated
  using      (public.rq_viewer_role() is distinct from 'sheikh' or public.rq_student_in_my_circles(student_id))
  with check (public.rq_viewer_role() is distinct from 'sheikh' or public.rq_student_in_my_circles(student_id));

-- ───────── 3) بوابة ولي الأمر: تقرير اليوم والإحصائية الشهرية تُقرأ مباشرة من rq_reports ─────────
create or replace function public.rq_parent_portal(p_national_id text, p_today date default current_date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  nid text := regexp_replace(coalesce(p_national_id,''), '\s', '', 'g');
  base jsonb; sid uuid; att jsonb; alr jsonb := '[]'::jsonb; msg jsonb; ach jsonb; tod jsonb; dys jsonb;
  run int := 0; r record; pct numeric;
begin
  base := public.rq_student_portal(nid, p_today);
  select id into sid from public.rq_students where national_id = nid limit 1;
  if sid is null or base is null or jsonb_array_length(coalesce(base->'students','[]'::jsonb)) = 0 then return base; end if;

  -- تقرير اليوم (مباشرة من الجدول، فلا يتأخر)
  select jsonb_build_object('date', report_date, 'status', status, 'hifz_pages', hifz_pages,
                            'murajaa_pages', murajaa_pages, 'entry', coalesce(entry, '{}'::jsonb))
    into tod from public.rq_reports where student_id = sid and report_date = p_today limit 1;

  -- أيام الشهر الحالي (للإحصائية والتقويم والرسوم)
  select coalesce(jsonb_agg(jsonb_build_object('d', report_date, 'status', status,
                                               'hifz', hifz_pages, 'murajaa', murajaa_pages) order by report_date), '[]'::jsonb)
    into dys from public.rq_reports
   where student_id = sid and report_date >= date_trunc('month', p_today)::date and report_date <= p_today;

  select coalesce(jsonb_agg(jsonb_build_object('date', report_date, 'status', status) order by report_date desc), '[]'::jsonb)
    into att from public.rq_reports where student_id = sid and report_date > p_today - 30 and report_date <= p_today;

  for r in select status from public.rq_reports where student_id = sid and report_date <= p_today order by report_date desc limit 14 loop
    if r.status = 'غائب' then run := run + 1; elsif r.status = 'غائب بعذر' then continue; else exit; end if;
  end loop;
  if run >= 2 then alr := alr || jsonb_build_array(jsonb_build_object('level','bad','text','غاب ابنك '||run||' أيام متتالية، يرجى التواصل مع المحفّظ.')); end if;

  select round(100.0 * count(*) filter (where status in ('حافظ','مقصر')) / nullif(count(*) filter (where status in ('حافظ','مقصر','غائب')),0))
    into pct from public.rq_reports where student_id = sid and report_date >= date_trunc('month', p_today)::date and report_date <= p_today;
  if pct is not null and pct < 60 then alr := alr || jsonb_build_array(jsonb_build_object('level','bad','text','نسبة حضور هذا الشهر '||pct||'٪ وهي أقل من المطلوب.')); end if;
  if tod is null then
    alr := alr || jsonb_build_array(jsonb_build_object('level','warn','text','لم يُسجَّل تقرير اليوم بعد.'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('direction', direction, 'body', body, 'at', created_at) order by created_at desc), '[]'::jsonb)
    into msg from (select * from public.rq_messages where student_id = sid order by created_at desc limit 40) m;
  select coalesce(jsonb_agg(jsonb_build_object('title', title, 'detail', detail, 'kind', kind, 'awarded_on', awarded_on) order by awarded_on desc), '[]'::jsonb)
    into ach from public.rq_achievements where student_id = sid;

  return jsonb_set(base, '{students,0}', (base->'students'->0)
    || jsonb_build_object('today', tod, 'days', dys, 'attendance', att, 'alerts', alr, 'messages', msg, 'achievements', ach));
end $$;
grant execute on function public.rq_parent_portal(text, date) to anon, authenticated;

notify pgrst, 'reload schema';

-- ───────── (اختياري) فحص: كم طالباً في كل حلقة ومن محفّظها؟ ─────────
-- select c.name as الحلقة, p.full_name as المحفّظ, count(s.id) as عدد_الطلاب
-- from rq_circles c left join rq_profiles p on p.user_id = c.sheikh_id left join rq_students s on s.circle_id = c.id
-- group by c.name, p.full_name order by 1;

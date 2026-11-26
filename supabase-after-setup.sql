-- شغّله مرة واحدة في Supabase → SQL Editor بعد rehab-parent-manager.sql
-- يغلق بوابة الطالب (بقيت الدالة متاحة للعامة رغم إزالة الواجهة)، ويبقي بوابة ولي الأمر فقط.
-- بوابة ولي الأمر تستدعيها داخلياً بصلاحية المالك (security definer) فلن تتأثر.
do $$
declare r record;
begin
  for r in select oid::regprocedure as sig from pg_proc
           where proname = 'rq_student_portal' and pronamespace = 'public'::regnamespace loop
    execute format('revoke execute on function %s from anon, public', r.sig);
  end loop;
end $$;

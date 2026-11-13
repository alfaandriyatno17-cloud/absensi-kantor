-- Karyawan yang sedang cuti (disetujui) tampil berstatus "cuti" di daftar kehadiran hari kerja.
-- Jalankan setelah 20261113_absensi_foto_jadwal_cuti.sql.
do $patch$
declare
  d text;
  o text := $o$'foto', e.foto_v, 'status', r.status,$o$;
  n text := $n$'foto', e.foto_v, 'status', coalesce(r.status, case when wd and exists (select 1 from public.abs_leaves l where l.employee_id = e.id and l.status = 'disetujui' and today between l.start_date and l.end_date) then 'cuti' end),$n$;
  cnt int;
begin
  d := pg_get_functiondef('public.abs_perform(text,text,text,inet,jsonb)'::regprocedure);
  if position('then ''cuti'' end' in d) > 0 then return; end if;
  cnt := (length(d) - length(replace(d, o, ''))) / length(o);
  if cnt <> 1 then raise exception 'patch board ditemukan % kali (harus tepat 1)', cnt; end if;
  execute replace(d, o, n);
end
$patch$;

revoke all on function public.abs_perform(text, text, text, inet, jsonb) from public, anon, authenticated;
grant execute on function public.abs_perform(text, text, text, inet, jsonb) to service_role;

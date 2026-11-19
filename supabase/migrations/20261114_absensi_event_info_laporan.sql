-- Event terkini, Informasi, Laporan kendala ke tim IT, dan teks Tentang Perusahaan (Visi/Misi/Profil).
-- Jalankan setelah 20261113_absensi_board_cuti.sql. Aman dijalankan ulang.

alter table public.abs_settings
  add column if not exists visi text not null default '',
  add column if not exists misi text not null default '',
  add column if not exists profil text not null default '';

create table if not exists public.abs_posts (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('event', 'info')),
  title text not null,
  body text not null default '',
  event_date date,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists abs_posts_idx on public.abs_posts (kind, event_date);

create table if not exists public.abs_reports (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.abs_employees(id) on delete cascade,
  message text not null,
  status text not null default 'baru' check (status in ('baru', 'selesai')),
  created_at timestamptz not null default now(),
  handled_at timestamptz
);
create index if not exists abs_reports_idx on public.abs_reports (status, created_at desc);

alter table public.abs_posts enable row level security;
alter table public.abs_reports enable row level security;
revoke all on public.abs_posts, public.abs_reports from anon, authenticated;

create or replace function public.abs_more(p_emp uuid, p_admin boolean, p_action text, p_payload jsonb, p_today date)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_id uuid; v_kind text; v_title text; v_body text; v_date date; v_msg text; v_st text;
  s public.abs_settings%rowtype;
begin
  if p_action = 'home' then
    select * into s from public.abs_settings where id = 1;
    return jsonb_build_object('ok', true, 'today', p_today,
      'events', coalesce((select jsonb_agg(x.j order by x.d) from (
          select e.event_date d, jsonb_build_object('id', e.id, 'title', e.title, 'body', e.body, 'date', e.event_date) j
          from public.abs_posts e where e.kind = 'event' and e.event_date >= p_today order by e.event_date limit 5) x), '[]'::jsonb),
      'about', jsonb_build_object('visi', s.visi, 'misi', s.misi, 'profil', s.profil),
      'upcoming', coalesce((select jsonb_agg(x.j order by x.sd) from (
          select l.start_date sd, jsonb_build_object('id', l.id, 'start', l.start_date, 'end', l.end_date, 'note', l.note, 'status', l.status) j
          from public.abs_leaves l where l.employee_id = p_emp and l.end_date >= p_today and l.status <> 'ditolak' order by l.start_date limit 20) x), '[]'::jsonb));

  elsif p_action = 'posts' then
    return jsonb_build_object('ok', true, 'today', p_today,
      'posts', coalesce((select jsonb_agg(x.j order by x.ca desc) from (
          select p.created_at ca, jsonb_build_object('id', p.id, 'kind', p.kind, 'title', p.title, 'body', p.body, 'date', p.event_date, 'created', p.created_at) j
          from public.abs_posts p order by p.created_at desc limit 100) x), '[]'::jsonb));

  elsif p_action = 'report_send' then
    v_msg := left(trim(coalesce(p_payload->>'message', '')), 500);
    if v_msg = '' then return jsonb_build_object('ok', false, 'error', 'pesan_kosong'); end if;
    if (select count(*) from public.abs_reports r where r.employee_id = p_emp and r.created_at > now() - interval '1 hour') >= 5 then
      return jsonb_build_object('ok', false, 'error', 'terlalu_sering');
    end if;
    insert into public.abs_reports (employee_id, message) values (p_emp, v_msg);
    return jsonb_build_object('ok', true);

  elsif p_action like 'admin\_%' then
    if not p_admin then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;

    if p_action = 'admin_post_save' then
      v_kind := p_payload->>'kind';
      v_title := left(trim(coalesce(p_payload->>'title', '')), 120);
      v_body := left(trim(coalesce(p_payload->>'body', '')), 1000);
      if v_kind is null or v_kind not in ('event', 'info') then return jsonb_build_object('ok', false, 'error', 'jenis_tidak_valid'); end if;
      if v_title = '' then return jsonb_build_object('ok', false, 'error', 'judul_kosong'); end if;
      begin
        v_date := nullif(p_payload->>'date', '')::date;
      exception when others then
        return jsonb_build_object('ok', false, 'error', 'tanggal_tidak_valid');
      end;
      if v_kind = 'event' and v_date is null then return jsonb_build_object('ok', false, 'error', 'tanggal_tidak_valid'); end if;
      if v_kind = 'info' then v_date := null; end if;
      begin
        v_id := nullif(p_payload->>'id', '')::uuid;
      exception when others then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end;
      if v_id is null then
        insert into public.abs_posts (kind, title, body, event_date, created_by) values (v_kind, v_title, v_body, v_date, p_emp);
      else
        update public.abs_posts p set kind = v_kind, title = v_title, body = v_body, event_date = v_date where p.id = v_id;
        if not found then return jsonb_build_object('ok', false, 'error', 'tidak_ada'); end if;
      end if;
      return jsonb_build_object('ok', true);

    elsif p_action = 'admin_post_del' then
      begin
        v_id := (p_payload->>'id')::uuid;
      exception when others then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end;
      delete from public.abs_posts p where p.id = v_id;
      return jsonb_build_object('ok', true);

    elsif p_action = 'admin_report_list' then
      return jsonb_build_object('ok', true, 'reports', coalesce((select jsonb_agg(x.j order by x.pri, x.ca desc) from (
          select case when r.status = 'baru' then 0 else 1 end pri, r.created_at ca,
                 jsonb_build_object('id', r.id, 'nama', e.nama, 'divisi', e.divisi, 'message', r.message, 'status', r.status, 'created', r.created_at) j
          from public.abs_reports r join public.abs_employees e on e.id = r.employee_id
          order by 1, 2 desc limit 200) x), '[]'::jsonb));

    elsif p_action = 'admin_report_set' then
      v_st := p_payload->>'status';
      if v_st is null or v_st not in ('baru', 'selesai') then return jsonb_build_object('ok', false, 'error', 'status_tidak_valid'); end if;
      begin
        v_id := (p_payload->>'id')::uuid;
      exception when others then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end;
      update public.abs_reports r set status = v_st, handled_at = case when v_st = 'selesai' then now() else null end where r.id = v_id;
      if not found then return jsonb_build_object('ok', false, 'error', 'tidak_ada'); end if;
      return jsonb_build_object('ok', true);

    elsif p_action = 'admin_report_del' then
      begin
        v_id := (p_payload->>'id')::uuid;
      exception when others then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end;
      delete from public.abs_reports r where r.id = v_id;
      return jsonb_build_object('ok', true);

    elsif p_action = 'admin_save_about' then
      update public.abs_settings t set
        visi = left(trim(coalesce(p_payload->>'visi', '')), 2000),
        misi = left(trim(coalesce(p_payload->>'misi', '')), 2000),
        profil = left(trim(coalesce(p_payload->>'profil', '')), 2000)
      where t.id = 1;
      return jsonb_build_object('ok', true);
    end if;
  end if;

  return jsonb_build_object('ok', false, 'error', 'aksi_tidak_dikenal');
end;
$function$;

revoke all on function public.abs_more(uuid, boolean, text, jsonb, date) from public, anon, authenticated;
grant execute on function public.abs_more(uuid, boolean, text, jsonb, date) to service_role;

-- Sambungkan ke abs_perform (dua cabang: karyawan dan admin), masing-masing tepat sekali.
do $patch$
declare
  d text;
  a1 text := $a$  elsif p_action = 'change_pin' then$a$;
  b1 text := $b$  elsif p_action in ('home', 'posts', 'report_send') then
    if emp.must_change_pin then
      return jsonb_build_object('ok', false, 'error', 'ganti_pin');
    end if;
    return public.abs_more(emp.id, emp.is_admin, p_action, p_payload, today);

  elsif p_action = 'change_pin' then$b$;
  a2 text := $a$    elsif p_action in ('admin_leave_list', 'admin_leave_decide', 'admin_leave_add', 'admin_leave_del') then$a$;
  b2 text := $b$    elsif p_action in ('admin_post_save', 'admin_post_del', 'admin_report_list', 'admin_report_set', 'admin_report_del', 'admin_save_about') then
      return public.abs_more(emp.id, emp.is_admin, p_action, p_payload, today);

    elsif p_action in ('admin_leave_list', 'admin_leave_decide', 'admin_leave_add', 'admin_leave_del') then$b$;
  c int;
begin
  d := pg_get_functiondef('public.abs_perform(text,text,text,inet,jsonb)'::regprocedure);
  if position('public.abs_more(' in d) > 0 then return; end if;
  c := (length(d) - length(replace(d, a1, ''))) / length(a1);
  if c <> 1 then raise exception 'patch karyawan ditemukan % kali (harus tepat 1)', c; end if;
  d := replace(d, a1, b1);
  c := (length(d) - length(replace(d, a2, ''))) / length(a2);
  if c <> 1 then raise exception 'patch admin ditemukan % kali (harus tepat 1)', c; end if;
  execute replace(d, a2, b2);
end
$patch$;

revoke all on function public.abs_perform(text, text, text, inet, jsonb) from public, anon, authenticated;
grant execute on function public.abs_perform(text, text, text, inet, jsonb) to service_role;

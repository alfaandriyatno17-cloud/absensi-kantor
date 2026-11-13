-- Foto profil, jadwal bulanan per karyawan, dan pengajuan cuti.
-- Jalankan setelah 20261112_absensi_kehadiran_board.sql.

alter table public.abs_employees add column if not exists foto_v bigint;

-- Foto disimpan di bucket publik (hanya JPEG kecil). Berkas diunggah oleh Edge Function dengan service_role.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('abs-foto', 'abs-foto', true, 153600, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 153600, allowed_mime_types = array['image/jpeg'];

create table if not exists public.abs_leaves (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.abs_employees(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  note text not null default '',
  status text not null default 'diajukan' check (status in ('diajukan', 'disetujui', 'ditolak')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  check (end_date >= start_date)
);
create index if not exists abs_leaves_emp_idx on public.abs_leaves (employee_id, start_date);
alter table public.abs_leaves enable row level security;
revoke all on public.abs_leaves from anon, authenticated;

create or replace function public.abs_extra(p_emp uuid, p_admin boolean, p_action text, p_payload jsonb, p_today date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $f$
declare
  v_month text; v_ms date; v_me date; v_target uuid; v_s date; v_e date; v_note text; v_id uuid; v_st text; v_v bigint;
  tgt public.abs_employees%rowtype; v_tz text;
begin
  select s.tz into v_tz from public.abs_settings s where s.id = 1;

  if p_action = 'schedule' then
    v_month := coalesce(p_payload->>'month', to_char(p_today, 'YYYY-MM'));
    if v_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then v_month := to_char(p_today, 'YYYY-MM'); end if;
    v_ms := (v_month || '-01')::date;
    v_me := (v_ms + interval '1 month')::date;
    v_target := p_emp;
    if p_admin and coalesce(p_payload->>'emp', '') <> '' then
      begin
        v_target := (p_payload->>'emp')::uuid;
      exception when others then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end;
    end if;
    select * into tgt from public.abs_employees e where e.id = v_target;
    if not found then return jsonb_build_object('ok', false, 'error', 'tidak_ada'); end if;
    return jsonb_build_object('ok', true, 'month', v_month, 'today', p_today,
      'emp', jsonb_build_object('id', tgt.id, 'nama', tgt.nama, 'divisi', tgt.divisi, 'foto', tgt.foto_v, 'wajib', tgt.ikut_absen,
                                'since', (tgt.created_at at time zone v_tz)::date),
      'records', coalesce((select jsonb_agg(jsonb_build_object('date', r.work_date, 'in', r.check_in, 'out', r.check_out, 'status', r.status, 'late', r.late_minutes, 'note', r.note) order by r.work_date)
                           from public.abs_records r where r.employee_id = v_target and r.work_date >= v_ms and r.work_date < v_me), '[]'::jsonb),
      'leaves', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'start', l.start_date, 'end', l.end_date, 'note', l.note, 'status', l.status) order by l.start_date)
                          from public.abs_leaves l where l.employee_id = v_target and l.start_date < v_me and l.end_date >= v_ms), '[]'::jsonb),
      'upcoming', coalesce((select jsonb_agg(x.j order by x.sd) from (select l.start_date sd, jsonb_build_object('id', l.id, 'start', l.start_date, 'end', l.end_date, 'note', l.note, 'status', l.status) j
                          from public.abs_leaves l where l.employee_id = v_target and l.end_date >= p_today and l.status <> 'ditolak' order by l.start_date limit 20) x), '[]'::jsonb));

  elsif p_action in ('leave_request', 'admin_leave_add') then
    begin
      v_s := (p_payload->>'start')::date;
      v_e := (p_payload->>'end')::date;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'tanggal_tidak_valid');
    end;
    if v_s is null or v_e is null or v_e < v_s then return jsonb_build_object('ok', false, 'error', 'tanggal_tidak_valid'); end if;
    if v_e - v_s > 59 then return jsonb_build_object('ok', false, 'error', 'cuti_terlalu_panjang'); end if;
    v_note := left(trim(coalesce(p_payload->>'note', '')), 140);
    v_target := p_emp;
    if p_action = 'admin_leave_add' then
      begin
        v_target := (p_payload->>'emp')::uuid;
      exception when others then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end;
      if not exists (select 1 from public.abs_employees e where e.id = v_target) then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end if;
    elsif v_s < p_today then
      return jsonb_build_object('ok', false, 'error', 'cuti_lampau');
    end if;
    if exists (select 1 from public.abs_leaves l where l.employee_id = v_target and l.status <> 'ditolak' and l.start_date <= v_e and l.end_date >= v_s) then
      return jsonb_build_object('ok', false, 'error', 'tumpang_tindih');
    end if;
    insert into public.abs_leaves (employee_id, start_date, end_date, note, status, decided_by, decided_at)
    values (v_target, v_s, v_e, v_note,
            case when p_action = 'admin_leave_add' then 'disetujui' else 'diajukan' end,
            case when p_action = 'admin_leave_add' then p_emp else null end,
            case when p_action = 'admin_leave_add' then now() else null end);
    return jsonb_build_object('ok', true);

  elsif p_action = 'leave_cancel' then
    begin
      v_id := (p_payload->>'id')::uuid;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'tidak_ada');
    end;
    delete from public.abs_leaves l
    where l.id = v_id and l.employee_id = p_emp and (l.status = 'diajukan' or l.start_date > p_today);
    if not found then return jsonb_build_object('ok', false, 'error', 'tidak_bisa_batal'); end if;
    return jsonb_build_object('ok', true);

  elsif p_action = 'photo_set' then
    v_v := (extract(epoch from clock_timestamp()) * 1000)::bigint;
    update public.abs_employees e set foto_v = v_v where e.id = p_emp;
    return jsonb_build_object('ok', true, 'id', p_emp, 'foto', v_v);

  elsif p_action = 'photo_del' then
    v_target := p_emp;
    if p_admin and coalesce(p_payload->>'id', '') <> '' then
      begin
        v_target := (p_payload->>'id')::uuid;
      exception when others then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end;
    end if;
    update public.abs_employees e set foto_v = null where e.id = v_target;
    if not found then return jsonb_build_object('ok', false, 'error', 'tidak_ada'); end if;
    return jsonb_build_object('ok', true, 'id', v_target);

  elsif p_action = 'admin_leave_list' then
    if not p_admin then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
    return jsonb_build_object('ok', true, 'leaves', coalesce((select jsonb_agg(x.j order by x.pri, x.sd desc) from (
      select case when l.status = 'diajukan' then 0 else 1 end pri, l.start_date sd,
             jsonb_build_object('id', l.id, 'emp', l.employee_id, 'nama', e.nama, 'divisi', e.divisi, 'start', l.start_date, 'end', l.end_date, 'note', l.note, 'status', l.status) j
      from public.abs_leaves l join public.abs_employees e on e.id = l.employee_id
      where l.status = 'diajukan' or l.end_date >= p_today - 60
      order by 1, 2 desc limit 300) x), '[]'::jsonb));

  elsif p_action = 'admin_leave_decide' then
    if not p_admin then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
    v_st := p_payload->>'status';
    if v_st is null or v_st not in ('disetujui', 'ditolak') then return jsonb_build_object('ok', false, 'error', 'status_tidak_valid'); end if;
    begin
      v_id := (p_payload->>'id')::uuid;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'tidak_ada');
    end;
    update public.abs_leaves l set status = v_st, decided_by = p_emp, decided_at = now() where l.id = v_id;
    if not found then return jsonb_build_object('ok', false, 'error', 'tidak_ada'); end if;
    return jsonb_build_object('ok', true);

  elsif p_action = 'admin_leave_del' then
    if not p_admin then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
    begin
      v_id := (p_payload->>'id')::uuid;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'tidak_ada');
    end;
    delete from public.abs_leaves l where l.id = v_id;
    return jsonb_build_object('ok', true);
  end if;

  return jsonb_build_object('ok', false, 'error', 'aksi_tidak_dikenal');
end;
$f$;
revoke all on function public.abs_extra(uuid, boolean, text, jsonb, date) from public, anon, authenticated;
grant execute on function public.abs_extra(uuid, boolean, text, jsonb, date) to service_role;

do $patch$
declare
  d text;
  pr text[][];
  i int;
  o text;
  n text;
  cnt int;
begin
  d := pg_get_functiondef('public.abs_perform(text,text,text,inet,jsonb)'::regprocedure);
  if position('abs_extra' in d) > 0 then return; end if;  -- sudah terpasang
  pr := array[
    array[$o$'admin', emp.is_admin, 'must_change_pin', emp.must_change_pin,$o$,
          $n$'admin', emp.is_admin, 'foto', emp.foto_v, 'must_change_pin', emp.must_change_pin,$n$],
    array[$o$'today_rec', (select jsonb_build_object($o$,
          $n$'leaves', coalesce((select jsonb_agg(jsonb_build_object('start', l.start_date, 'end', l.end_date, 'status', l.status))
                           from public.abs_leaves l where l.employee_id = emp.id and l.status = 'disetujui' and l.start_date < (v_ms + interval '1 month')::date and l.end_date >= v_ms), '[]'::jsonb),
      'today_rec', (select jsonb_build_object($n$],
    array[$o$'divisi', e.divisi, 'status', r.status,$o$,
          $n$'divisi', e.divisi, 'foto', e.foto_v, 'status', r.status,$n$],
    array[$o$'wajib', e.ikut_absen, 'must_change_pin', e.must_change_pin,$o$,
          $n$'wajib', e.ikut_absen, 'foto', e.foto_v, 'must_change_pin', e.must_change_pin,$n$],
    array[$o$'ips', coalesce((select jsonb_agg(jsonb_build_object('id', o.id,$o$,
          $n$'leaves', coalesce((select jsonb_agg(jsonb_build_object('emp', l.employee_id, 'start', l.start_date, 'end', l.end_date, 'status', l.status))
                           from public.abs_leaves l where l.status = 'disetujui' and l.start_date < (v_ms + interval '1 month')::date and l.end_date >= v_ms), '[]'::jsonb),
        'ips', coalesce((select jsonb_agg(jsonb_build_object('id', o.id,$n$],
    array[$o$elsif p_action = 'change_pin' then$o$,
          $n$elsif p_action in ('schedule', 'leave_request', 'leave_cancel', 'photo_set', 'photo_del') then
    if emp.must_change_pin then
      return jsonb_build_object('ok', false, 'error', 'ganti_pin');
    end if;
    return public.abs_extra(emp.id, emp.is_admin, p_action, p_payload, today);

  elsif p_action = 'change_pin' then$n$],
    array[$o$elsif p_action = 'admin_add_ip' then$o$,
          $n$elsif p_action in ('admin_leave_list', 'admin_leave_decide', 'admin_leave_add', 'admin_leave_del') then
      return public.abs_extra(emp.id, emp.is_admin, p_action, p_payload, today);

    elsif p_action = 'admin_add_ip' then$n$]
  ];
  for i in 1 .. array_length(pr, 1) loop
    o := pr[i][1]; n := pr[i][2];
    cnt := (length(d) - length(replace(d, o, ''))) / length(o);
    if cnt <> 1 then raise exception 'patch % ditemukan % kali (harus tepat 1)', i, cnt; end if;
    d := replace(d, o, n);
  end loop;
  execute d;
end
$patch$;

revoke all on function public.abs_perform(text, text, text, inet, jsonb) from public, anon, authenticated;
grant execute on function public.abs_perform(text, text, text, inet, jsonb) to service_role;

-- Absensi karyawan dengan pembatasan IP kantor.
-- Semua objek berawalan abs_ dan terpisah dari tabel akt_ (akuntansi) dan kasir_.
-- Tabel hanya bisa diakses lewat fungsi abs_perform yang dipanggil Edge Function `absen`
-- dengan service_role. anon dan authenticated tidak punya akses langsung.

create table public.abs_settings (
  id int primary key default 1 check (id = 1),
  company text not null default '',
  start_time text not null default '08:00',
  end_time text not null default '17:00',
  grace int not null default 10,
  workdays int[] not null default '{1,2,3,4,5}',
  libur date[] not null default '{}',
  tz text not null default 'Asia/Jakarta',
  enforce_ip boolean not null default true
);
insert into public.abs_settings (id) values (1);

create table public.abs_employees (
  id uuid primary key default gen_random_uuid(),
  kode text not null,
  nama text not null,
  divisi text not null default '',
  pin_hash text not null,
  is_admin boolean not null default false,
  aktif boolean not null default true,
  must_change_pin boolean not null default true,
  failed_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
create unique index abs_employees_kode_uq on public.abs_employees (lower(kode));

create table public.abs_office_ips (
  id uuid primary key default gen_random_uuid(),
  ip inet not null,
  label text not null default '',
  created_at timestamptz not null default now()
);

create table public.abs_records (
  employee_id uuid not null references public.abs_employees(id) on delete cascade,
  work_date date not null,
  check_in timestamptz,
  check_out timestamptz,
  status text not null check (status in ('hadir','terlambat','izin','sakit')),
  late_minutes int not null default 0,
  note text not null default '',
  in_ip inet,
  out_ip inet,
  edited_by uuid,
  edited_at timestamptz,
  primary key (employee_id, work_date)
);

create table public.abs_denied (
  id bigserial primary key,
  employee_id uuid references public.abs_employees(id) on delete cascade,
  ip inet,
  action text,
  at timestamptz not null default now()
);

create table public.abs_ip_fail (
  ip inet primary key,
  n int not null default 1,
  since timestamptz not null default now()
);

comment on table public.abs_employees is 'Absensi: karyawan, login memakai kode + PIN (bukan Supabase Auth).';
comment on table public.abs_office_ips is 'Absensi: daftar IP/CIDR publik kantor yang diizinkan untuk absen masuk dan pulang.';

alter table public.abs_settings enable row level security;
alter table public.abs_employees enable row level security;
alter table public.abs_office_ips enable row level security;
alter table public.abs_records enable row level security;
alter table public.abs_denied enable row level security;
alter table public.abs_ip_fail enable row level security;

revoke all on public.abs_settings, public.abs_employees, public.abs_office_ips, public.abs_records, public.abs_denied, public.abs_ip_fail from anon, authenticated;
revoke all on sequence public.abs_denied_id_seq from anon, authenticated;

create or replace function public.abs_hm_to_min(t text) returns int
language sql immutable
set search_path = public
as $$ select split_part(t, ':', 1)::int * 60 + split_part(t, ':', 2)::int $$;

create or replace function public.abs_local_min(ts timestamptz, tz text) returns int
language sql stable
set search_path = public
as $$
  select extract(hour from (ts at time zone tz))::int * 60 + extract(minute from (ts at time zone tz))::int
$$;

create or replace function public.abs_new_pin() returns text
language sql volatile
set search_path = public, extensions
as $$ select lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0') $$;

-- Catatan: kondisi `if ... case ... then` tidak boleh dipakai di PL/pgSQL (parser berhenti di `then` pertama),
-- karena itu nilai case dipindahkan ke variabel dulu.
create or replace function public.abs_perform(
  p_kode text, p_pin text, p_action text, p_ip inet, p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  cfg public.abs_settings%rowtype;
  emp public.abs_employees%rowtype;
  rec public.abs_records%rowtype;
  fails public.abs_ip_fail%rowtype;
  in_office boolean;
  nowt timestamptz := now();
  today date;
  mins int;
  startm int;
  wd boolean;
  v_wd2 boolean;
  v_minlen int;
  v_status text;
  v_late int;
  v_ms date;
  v_month text;
  v_tmp text;
  v_ip inet;
  v_date date;
  v_in timestamptz;
  v_out timestamptz;
  v_note text;
  v_id uuid;
  v_kode text;
  v_nama text;
  v_div text;
  v_admin boolean;
  v_aktif boolean;
  cfg_json jsonb;
begin
  select * into cfg from public.abs_settings where id = 1;
  in_office := (not cfg.enforce_ip) or exists (select 1 from public.abs_office_ips o where p_ip <<= o.ip);
  today := (nowt at time zone cfg.tz)::date;
  cfg_json := jsonb_build_object('company', cfg.company, 'start', cfg.start_time, 'end', cfg.end_time, 'grace', cfg.grace,
    'workdays', to_jsonb(cfg.workdays), 'libur', to_jsonb(cfg.libur), 'tz', cfg.tz, 'enforce', cfg.enforce_ip);

  if p_action = 'ping' then
    return jsonb_build_object('ok', true, 'ip', host(p_ip), 'kantor', in_office, 'enforce', cfg.enforce_ip, 'company', cfg.company);
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then p_payload := '{}'::jsonb; end if;

  -- pembatas percobaan login per IP
  if p_ip is not null then
    select * into fails from public.abs_ip_fail where ip = p_ip;
    if found and fails.since > nowt - interval '15 minutes' and fails.n >= 20 then
      return jsonb_build_object('ok', false, 'error', 'terlalu_banyak');
    end if;
  end if;

  select * into emp from public.abs_employees e where lower(e.kode) = lower(trim(coalesce(p_kode, ''))) and e.aktif;
  if not found or (emp.locked_until is not null and emp.locked_until > nowt) then
    if p_ip is not null then
      insert into public.abs_ip_fail (ip, n, since) values (p_ip, 1, nowt)
      on conflict (ip) do update set
        n = case when public.abs_ip_fail.since < nowt - interval '15 minutes' then 1 else public.abs_ip_fail.n + 1 end,
        since = case when public.abs_ip_fail.since < nowt - interval '15 minutes' then nowt else public.abs_ip_fail.since end;
    end if;
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;

  if p_pin is null or emp.pin_hash is distinct from crypt(p_pin, emp.pin_hash) then
    update public.abs_employees e set
      failed_attempts = e.failed_attempts + 1,
      locked_until = case when e.failed_attempts + 1 >= 5 then nowt + interval '15 minutes' else e.locked_until end
    where e.id = emp.id;
    if p_ip is not null then
      insert into public.abs_ip_fail (ip, n, since) values (p_ip, 1, nowt)
      on conflict (ip) do update set
        n = case when public.abs_ip_fail.since < nowt - interval '15 minutes' then 1 else public.abs_ip_fail.n + 1 end,
        since = case when public.abs_ip_fail.since < nowt - interval '15 minutes' then nowt else public.abs_ip_fail.since end;
    end if;
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;

  if emp.failed_attempts <> 0 or emp.locked_until is not null then
    update public.abs_employees e set failed_attempts = 0, locked_until = null where e.id = emp.id;
  end if;

  v_month := coalesce(p_payload->>'month', to_char(today, 'YYYY-MM'));
  if v_month !~ '^\d{4}-\d{2}$' then v_month := to_char(today, 'YYYY-MM'); end if;
  begin
    v_ms := (v_month || '-01')::date;
  exception when others then
    v_ms := date_trunc('month', today)::date;
  end;

  wd := (extract(dow from today)::int = any(cfg.workdays)) and not (today = any(cfg.libur));
  startm := public.abs_hm_to_min(cfg.start_time);

  -- ===== aksi karyawan =====
  if p_action = 'status' then
    return jsonb_build_object('ok', true, 'ip', host(p_ip), 'kantor', in_office, 'today', today, 'server_time', nowt,
      'me', jsonb_build_object('id', emp.id, 'kode', emp.kode, 'nama', emp.nama, 'divisi', emp.divisi, 'admin', emp.is_admin, 'must_change_pin', emp.must_change_pin, 'since', (emp.created_at at time zone cfg.tz)::date),
      'cfg', cfg_json,
      'records', coalesce((select jsonb_agg(jsonb_build_object('date', r.work_date, 'in', r.check_in, 'out', r.check_out, 'status', r.status, 'late', r.late_minutes, 'note', r.note) order by r.work_date)
                           from public.abs_records r where r.employee_id = emp.id and r.work_date >= v_ms and r.work_date < (v_ms + interval '1 month')::date), '[]'::jsonb),
      'today_rec', (select jsonb_build_object('date', r.work_date, 'in', r.check_in, 'out', r.check_out, 'status', r.status, 'late', r.late_minutes, 'note', r.note)
                    from public.abs_records r where r.employee_id = emp.id and r.work_date = today));

  elsif p_action = 'change_pin' then
    v_tmp := coalesce(p_payload->>'new_pin', '');
    if length(v_tmp) < 6 or length(v_tmp) > 12 then
      return jsonb_build_object('ok', false, 'error', 'pin_pendek');
    end if;
    if v_tmp = p_pin then
      return jsonb_build_object('ok', false, 'error', 'pin_sama');
    end if;
    update public.abs_employees e set pin_hash = crypt(v_tmp, gen_salt('bf')), must_change_pin = false where e.id = emp.id;
    return jsonb_build_object('ok', true);

  elsif p_action in ('in', 'out') then
    if emp.must_change_pin then
      return jsonb_build_object('ok', false, 'error', 'ganti_pin');
    end if;
    if not in_office then
      delete from public.abs_denied d where d.at < nowt - interval '90 days';
      insert into public.abs_denied (employee_id, ip, action) values (emp.id, p_ip, p_action);
      return jsonb_build_object('ok', false, 'error', 'luar_kantor', 'ip', host(p_ip));
    end if;
    select * into rec from public.abs_records r where r.employee_id = emp.id and r.work_date = today;
    if p_action = 'in' then
      if found then
        return jsonb_build_object('ok', false, 'error', 'sudah');
      end if;
      mins := public.abs_local_min(nowt, cfg.tz);
      if wd and mins - startm > cfg.grace then
        v_status := 'terlambat'; v_late := mins - startm;
      else
        v_status := 'hadir'; v_late := 0;
      end if;
      insert into public.abs_records (employee_id, work_date, check_in, status, late_minutes, note, in_ip)
      values (emp.id, today, nowt, v_status, v_late, case when wd then '' else 'Hari libur' end, p_ip);
      return jsonb_build_object('ok', true, 'action', 'in', 'status', v_status, 'late', v_late);
    else
      if not found or rec.check_in is null then
        return jsonb_build_object('ok', false, 'error', 'belum_masuk');
      end if;
      if rec.check_out is not null then
        return jsonb_build_object('ok', false, 'error', 'sudah');
      end if;
      update public.abs_records r set check_out = nowt, out_ip = p_ip where r.employee_id = emp.id and r.work_date = today;
      return jsonb_build_object('ok', true, 'action', 'out');
    end if;

  elsif p_action = 'leave' then
    -- izin/sakit boleh dilaporkan dari mana saja
    v_status := p_payload->>'status';
    v_note := left(trim(coalesce(p_payload->>'note', '')), 140);
    if v_status is null or v_status not in ('izin', 'sakit') then
      return jsonb_build_object('ok', false, 'error', 'status_tidak_valid');
    end if;
    if v_note = '' then
      return jsonb_build_object('ok', false, 'error', 'catatan_kosong');
    end if;
    if exists (select 1 from public.abs_records r where r.employee_id = emp.id and r.work_date = today) then
      return jsonb_build_object('ok', false, 'error', 'sudah');
    end if;
    insert into public.abs_records (employee_id, work_date, status, late_minutes, note) values (emp.id, today, v_status, 0, v_note);
    return jsonb_build_object('ok', true);
  end if;

  -- ===== aksi admin =====
  if p_action like 'admin\_%' then
    if not emp.is_admin then
      return jsonb_build_object('ok', false, 'error', 'forbidden');
    end if;

    if p_action = 'admin_overview' then
      return jsonb_build_object('ok', true, 'ip', host(p_ip), 'kantor', in_office, 'today', today, 'cfg', cfg_json, 'me_id', emp.id,
        'employees', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kode', e.kode, 'nama', e.nama, 'divisi', e.divisi, 'admin', e.is_admin, 'aktif', e.aktif, 'must_change_pin', e.must_change_pin, 'since', (e.created_at at time zone cfg.tz)::date) order by lower(e.nama)) from public.abs_employees e), '[]'::jsonb),
        'records', coalesce((select jsonb_agg(jsonb_build_object('emp', r.employee_id, 'date', r.work_date, 'in', r.check_in, 'out', r.check_out, 'status', r.status, 'late', r.late_minutes, 'note', r.note, 'in_ip', host(r.in_ip)))
                             from public.abs_records r where r.work_date >= v_ms and r.work_date < (v_ms + interval '1 month')::date), '[]'::jsonb),
        'ips', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'ip', abbrev(o.ip), 'label', o.label, 'created', o.created_at) order by o.created_at) from public.abs_office_ips o), '[]'::jsonb),
        'denied', coalesce((select jsonb_agg(x.j order by x.at desc) from (select d.at, jsonb_build_object('emp', d.employee_id, 'ip', host(d.ip), 'action', d.action, 'at', d.at) j from public.abs_denied d order by d.at desc limit 30) x), '[]'::jsonb));

    elsif p_action = 'admin_add_ip' then
      if coalesce((p_payload->>'use_current')::boolean, false) then
        if p_ip is null then
          return jsonb_build_object('ok', false, 'error', 'ip_tidak_terbaca');
        end if;
        if family(p_ip) = 6 then
          v_ip := network(set_masklen(p_ip, 64))::inet;
        else
          v_ip := set_masklen(p_ip, 32);
        end if;
      else
        begin
          v_ip := (p_payload->>'ip')::inet;
        exception when others then
          return jsonb_build_object('ok', false, 'error', 'ip_tidak_valid');
        end;
        if v_ip is null then
          return jsonb_build_object('ok', false, 'error', 'ip_tidak_valid');
        end if;
      end if;
      v_minlen := case when family(v_ip) = 4 then 16 else 48 end;
      if masklen(v_ip) < v_minlen then
        return jsonb_build_object('ok', false, 'error', 'terlalu_luas');
      end if;
      if exists (select 1 from public.abs_office_ips o where o.ip = v_ip) then
        return jsonb_build_object('ok', false, 'error', 'sudah_ada');
      end if;
      insert into public.abs_office_ips (ip, label) values (v_ip, left(trim(coalesce(p_payload->>'label', '')), 60));
      return jsonb_build_object('ok', true, 'ip', abbrev(v_ip));

    elsif p_action = 'admin_del_ip' then
      delete from public.abs_office_ips o where o.id = (p_payload->>'id')::uuid;
      return jsonb_build_object('ok', true);

    elsif p_action = 'admin_save_employee' then
      v_kode := trim(coalesce(p_payload->>'kode', ''));
      v_nama := trim(coalesce(p_payload->>'nama', ''));
      v_div := left(trim(coalesce(p_payload->>'divisi', '')), 60);
      v_admin := coalesce((p_payload->>'admin')::boolean, false);
      v_aktif := coalesce((p_payload->>'aktif')::boolean, true);
      v_id := nullif(p_payload->>'id', '')::uuid;
      if v_kode !~ '^[A-Za-z0-9._-]{2,30}$' then
        return jsonb_build_object('ok', false, 'error', 'kode_tidak_valid');
      end if;
      if v_nama = '' or length(v_nama) > 80 then
        return jsonb_build_object('ok', false, 'error', 'nama_kosong');
      end if;
      if exists (select 1 from public.abs_employees e where lower(e.kode) = lower(v_kode) and (v_id is null or e.id <> v_id)) then
        return jsonb_build_object('ok', false, 'error', 'kode_dipakai');
      end if;
      if v_id is null then
        v_tmp := public.abs_new_pin();
        insert into public.abs_employees (kode, nama, divisi, is_admin, aktif, pin_hash, must_change_pin)
        values (v_kode, v_nama, v_div, v_admin, v_aktif, crypt(v_tmp, gen_salt('bf')), true);
        return jsonb_build_object('ok', true, 'pin', v_tmp);
      else
        if v_id = emp.id and (not v_admin or not v_aktif) then
          return jsonb_build_object('ok', false, 'error', 'diri_sendiri');
        end if;
        update public.abs_employees e set kode = v_kode, nama = v_nama, divisi = v_div, is_admin = v_admin, aktif = v_aktif where e.id = v_id;
        if not found then
          return jsonb_build_object('ok', false, 'error', 'tidak_ada');
        end if;
        return jsonb_build_object('ok', true);
      end if;

    elsif p_action = 'admin_reset_pin' then
      v_tmp := public.abs_new_pin();
      update public.abs_employees e set pin_hash = crypt(v_tmp, gen_salt('bf')), must_change_pin = true, failed_attempts = 0, locked_until = null
      where e.id = (p_payload->>'id')::uuid;
      if not found then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end if;
      return jsonb_build_object('ok', true, 'pin', v_tmp);

    elsif p_action = 'admin_edit_record' then
      v_id := (p_payload->>'emp')::uuid;
      v_date := (p_payload->>'date')::date;
      v_status := coalesce(p_payload->>'status', 'auto');
      v_note := left(trim(coalesce(p_payload->>'note', '')), 140);
      if not exists (select 1 from public.abs_employees e where e.id = v_id) then
        return jsonb_build_object('ok', false, 'error', 'tidak_ada');
      end if;
      if v_date > today then
        return jsonb_build_object('ok', false, 'error', 'tanggal_depan');
      end if;
      if v_status in ('izin', 'sakit') then
        insert into public.abs_records (employee_id, work_date, check_in, check_out, status, late_minutes, note, edited_by, edited_at)
        values (v_id, v_date, null, null, v_status, 0, v_note, emp.id, nowt)
        on conflict (employee_id, work_date) do update set check_in = null, check_out = null, status = excluded.status, late_minutes = 0,
          note = excluded.note, edited_by = excluded.edited_by, edited_at = excluded.edited_at;
      else
        if coalesce(p_payload->>'in_time', '') = '' then
          return jsonb_build_object('ok', false, 'error', 'jam_masuk');
        end if;
        v_in := (v_date + (p_payload->>'in_time')::time) at time zone cfg.tz;
        if coalesce(p_payload->>'out_time', '') = '' then
          v_out := null;
        else
          v_out := (v_date + (p_payload->>'out_time')::time) at time zone cfg.tz;
        end if;
        if v_out is not null and v_out <= v_in then
          return jsonb_build_object('ok', false, 'error', 'jam_pulang');
        end if;
        mins := public.abs_local_min(v_in, cfg.tz);
        v_wd2 := (extract(dow from v_date)::int = any(cfg.workdays)) and not (v_date = any(cfg.libur));
        if v_wd2 and mins - startm > cfg.grace then
          v_status := 'terlambat'; v_late := mins - startm;
        else
          v_status := 'hadir'; v_late := 0;
        end if;
        insert into public.abs_records (employee_id, work_date, check_in, check_out, status, late_minutes, note, edited_by, edited_at)
        values (v_id, v_date, v_in, v_out, v_status, v_late, v_note, emp.id, nowt)
        on conflict (employee_id, work_date) do update set check_in = excluded.check_in, check_out = excluded.check_out, status = excluded.status,
          late_minutes = excluded.late_minutes, note = excluded.note, edited_by = excluded.edited_by, edited_at = excluded.edited_at;
      end if;
      return jsonb_build_object('ok', true);

    elsif p_action = 'admin_del_record' then
      delete from public.abs_records r where r.employee_id = (p_payload->>'emp')::uuid and r.work_date = (p_payload->>'date')::date;
      return jsonb_build_object('ok', true);

    elsif p_action = 'admin_save_settings' then
      if coalesce(p_payload->>'start', '') !~ '^\d{2}:\d{2}$' or coalesce(p_payload->>'end', '') !~ '^\d{2}:\d{2}$' then
        return jsonb_build_object('ok', false, 'error', 'jam_tidak_valid');
      end if;
      if public.abs_hm_to_min(p_payload->>'start') >= public.abs_hm_to_min(p_payload->>'end') then
        return jsonb_build_object('ok', false, 'error', 'jam_urutan');
      end if;
      if coalesce(p_payload->>'tz', '') not in ('Asia/Jakarta', 'Asia/Makassar', 'Asia/Jayapura') then
        return jsonb_build_object('ok', false, 'error', 'zona_tidak_valid');
      end if;
      update public.abs_settings s set
        company = left(trim(coalesce(p_payload->>'company', '')), 60),
        start_time = p_payload->>'start',
        end_time = p_payload->>'end',
        grace = greatest(0, least(120, coalesce((p_payload->>'grace')::int, 0))),
        workdays = coalesce((select array_agg(v::int) from jsonb_array_elements_text(coalesce(p_payload->'workdays', '[]'::jsonb)) v), '{}'),
        libur = coalesce((select array_agg(v::date order by v::date) from jsonb_array_elements_text(coalesce(p_payload->'libur', '[]'::jsonb)) v), '{}'),
        tz = p_payload->>'tz',
        enforce_ip = coalesce((p_payload->>'enforce')::boolean, true)
      where s.id = 1;
      return jsonb_build_object('ok', true);
    end if;
  end if;

  return jsonb_build_object('ok', false, 'error', 'aksi_tidak_dikenal');
end;
$fn$;

revoke all on function public.abs_perform(text, text, text, inet, jsonb) from public, anon, authenticated;
grant execute on function public.abs_perform(text, text, text, inet, jsonb) to service_role;
revoke all on function public.abs_new_pin() from public, anon, authenticated;
revoke all on function public.abs_hm_to_min(text) from public, anon, authenticated;
revoke all on function public.abs_local_min(timestamptz, text) from public, anon, authenticated;

-- Akun admin pertama TIDAK dibuat di sini agar PIN tidak tersimpan di repositori.
-- Buat satu kali lewat SQL Editor Supabase (PIN sementara tampil di hasil kueri, wajib diganti saat login pertama):
--   with p as (select public.abs_new_pin() as pin),
--   ins as (insert into public.abs_employees (kode, nama, divisi, is_admin, pin_hash, must_change_pin)
--           select 'admin', 'Administrator', 'Admin', true, crypt(p.pin, gen_salt('bf')), true from p returning kode)
--   select pin as pin_sementara from p;

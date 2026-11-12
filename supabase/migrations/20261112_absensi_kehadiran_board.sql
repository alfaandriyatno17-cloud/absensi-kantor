-- Daftar kehadiran hari ini untuk semua karyawan + opsi "wajib absen" per karyawan.
-- Jalankan setelah 20261112_absensi_ip_kantor.sql.
alter table public.abs_employees add column if not exists ikut_absen boolean not null default true;
-- akun pengelola awal tidak ikut dihitung sebagai karyawan yang wajib absen
update public.abs_employees set ikut_absen = false where lower(kode) = 'admin';

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
  if position($$p_action = 'board'$$ in d) > 0 then return; end if;  -- sudah terpasang
  pr := array[
    array[
      $o$elsif p_action = 'change_pin' then$o$,
      $n$elsif p_action = 'board' then
    -- boleh dilihat semua karyawan yang sudah login (tanpa catatan dan tanpa IP)
    return jsonb_build_object('ok', true, 'today', today, 'server_time', nowt,
      'list', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nama', e.nama, 'divisi', e.divisi, 'status', r.status, 'in', r.check_in, 'out', r.check_out, 'late', r.late_minutes) order by lower(e.nama))
                        from public.abs_employees e
                        left join public.abs_records r on r.employee_id = e.id and r.work_date = today
                        where e.aktif and e.ikut_absen), '[]'::jsonb));

  elsif p_action = 'change_pin' then$n$
    ],
    array[$o$'aktif', e.aktif, 'must_change_pin', e.must_change_pin, 'since'$o$,
          $n$'aktif', e.aktif, 'wajib', e.ikut_absen, 'must_change_pin', e.must_change_pin, 'since'$n$],
    array[$o$v_aktif boolean;$o$, $n$v_aktif boolean;
  v_wajib boolean;$n$],
    array[$o$v_aktif := coalesce((p_payload->>'aktif')::boolean, true);$o$,
          $n$v_aktif := coalesce((p_payload->>'aktif')::boolean, true);
      v_wajib := coalesce((p_payload->>'wajib')::boolean, true);$n$],
    array[$o$(kode, nama, divisi, is_admin, aktif, pin_hash, must_change_pin)$o$,
          $n$(kode, nama, divisi, is_admin, aktif, ikut_absen, pin_hash, must_change_pin)$n$],
    array[$o$values (v_kode, v_nama, v_div, v_admin, v_aktif, crypt($o$,
          $n$values (v_kode, v_nama, v_div, v_admin, v_aktif, v_wajib, crypt($n$],
    array[$o$is_admin = v_admin, aktif = v_aktif where e.id = v_id;$o$,
          $n$is_admin = v_admin, aktif = v_aktif, ikut_absen = v_wajib where e.id = v_id;$n$]
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

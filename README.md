# Absensi Karyawan (absen hanya dari jaringan kantor)

Halaman absensi satu berkas (`index.html`) dengan database Supabase. Absen masuk dan pulang hanya diterima kalau alamat IP pengirim ada di daftar IP kantor. Pemeriksaan dilakukan di server, bukan di halaman, jadi tidak bisa dilewati dari browser.

## Isi repositori

| Berkas | Fungsi |
| --- | --- |
| `index.html` | Halaman untuk karyawan dan admin. Tidak perlu build. |
| `supabase/functions/absen/index.ts` | Edge Function: membaca IP pengirim lalu memanggil fungsi database. |
| `supabase/migrations/20261112_absensi_ip_kantor.sql` | Tabel `abs_*` dan fungsi `abs_perform`. |

## Cara kerja

- Karyawan login dengan kode karyawan dan PIN, bukan akun Supabase Auth. PIN disimpan sebagai hash bcrypt.
- Edge Function `absen` memakai header `cf-connecting-ip` (diisi Cloudflare, tidak bisa dipalsukan klien) sebagai IP pengirim.
- Fungsi `abs_perform` memeriksa IP terhadap tabel `abs_office_ips`. Di luar daftar, absen masuk dan pulang ditolak dan dicatat di `abs_denied`. Izin dan sakit boleh dari mana saja.
- Semua tabel memakai RLS tanpa policy dan hak `anon`/`authenticated` dicabut. Data hanya bisa diakses lewat fungsi, dengan `service_role`.
- Akun terkunci 15 menit setelah 5 kali salah PIN. Satu IP dibatasi 20 percobaan gagal per 15 menit.
- Jam acuan adalah jam server, bukan jam perangkat.

## Pemasangan

1. Jalankan `supabase/migrations/20261112_absensi_ip_kantor.sql` di SQL Editor Supabase.
2. Buat admin pertama dengan kueri di bagian bawah berkas SQL itu. Catat PIN sementaranya, lalu ganti saat login pertama.
3. Deploy Edge Function: `supabase functions deploy absen --no-verify-jwt`.
4. Ubah konstanta `API` di `index.html` ke alamat fungsi di project Supabase Anda: `https://<project-ref>.supabase.co/functions/v1/absen`.
5. Hubungkan repositori ini ke Vercel (framework: Other, tanpa build command). Matikan Vercel Authentication supaya karyawan bisa membuka halaman tanpa akun Vercel.
6. Login sebagai admin dari WiFi kantor, buka tab **Jaringan**, lalu daftarkan jaringan yang sedang dipakai.

## Catatan

- Server hanya mengenali jaringan internet kantor (IP publik), bukan nama WiFi. LAN kabel kantor ikut lolos, kuota seluler ditolak.
- Jika provider mengganti IP kantor, daftarkan IP baru di tab **Jaringan**.
- Perangkat dengan IPv6 mendaftarkan seluruh blok /64. Daftarkan juga IPv4 kantor jika perangkat bisa berpindah antara keduanya.
- Repositori ini tidak berisi kunci atau PIN. Kunci `service_role` hanya ada di lingkungan Edge Function Supabase.

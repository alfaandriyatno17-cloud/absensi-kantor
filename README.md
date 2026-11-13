# Absensi Karyawan (absen hanya dari jaringan kantor)

Halaman absensi satu berkas (`index.html`) dengan database Supabase. Absen masuk dan pulang hanya diterima kalau alamat IP pengirim ada di daftar IP kantor. Pemeriksaan dilakukan di server, bukan di halaman, jadi tidak bisa dilewati dari browser.

## Isi repositori

| Berkas | Fungsi |
| --- | --- |
| `index.html` | Halaman untuk karyawan dan admin. Tidak perlu build. |
| `supabase/functions/absen/index.ts` | Edge Function: membaca IP pengirim lalu memanggil fungsi database. |
| `supabase/migrations/20261112_absensi_ip_kantor.sql` | Tabel `abs_*` dan fungsi `abs_perform`. |
| `supabase/migrations/20261112_absensi_kehadiran_board.sql` | Daftar kehadiran hari ini dan opsi "wajib absen". Jalankan setelah berkas di atas. |
| `supabase/migrations/20261113_absensi_foto_jadwal_cuti.sql` | Foto profil (bucket `abs-foto`), tabel cuti `abs_leaves`, dan aksi jadwal. |
| `supabase/migrations/20261113_absensi_board_cuti.sql` | Karyawan yang sedang cuti tampil berstatus Cuti di daftar kehadiran. |

## Tampilan

Halaman dibuat seperti aplikasi ponsel: kartu sapaan hijau dengan pintasan **Jadwal** dan **Pengajuan**, bagian **Aktivitas saya** (kartu Presensi dan kartu Cuti), serta navigasi bawah **Beranda, Riwayat, Kehadiran, Profil**. Tombol bulat hijau di tengah membawa karyawan ke kartu Presensi untuk absen. Admin mendapat pintasan **Kelola** untuk Cuti, Rekap, Karyawan, Jaringan, dan Pengaturan.

## Hak akses

- **Karyawan**: hanya tab **Absen** (absen sendiri dan riwayat sendiri), **Kehadiran** (siapa yang sudah dan belum absen hari ini, beserta jam masuk/pulang dan status izin/sakit; catatan dan IP tidak ditampilkan), dan **Jadwal** (kalender absensi sebulan milik sendiri, daftar izin dan cuti, serta pengajuan cuti). Karyawan juga bisa mengunggah foto profil lewat ikon bulat di pojok kanan atas.
- **Admin**: semua tab, yaitu Rekap, Karyawan (tambah, ubah, reset PIN, nonaktifkan), Jaringan, dan Pengaturan, plus koreksi catatan absen, melihat jadwal siapa pun, dan tab **Cuti** untuk menyetujui, menolak, menambah, atau menghapus cuti.
- Karyawan bisa dikecualikan dari daftar dengan mematikan **Wajib absen** di form karyawan (cocok untuk akun admin pengelola). Mereka tidak muncul di Kehadiran maupun Rekap.
- Pembatasan ini dijaga di server (`abs_perform`), bukan hanya disembunyikan di halaman.

## Cara kerja

- Karyawan login dengan kode karyawan dan PIN, bukan akun Supabase Auth. PIN disimpan sebagai hash bcrypt.
- Edge Function `absen` memakai header `cf-connecting-ip` (diisi Cloudflare, tidak bisa dipalsukan klien) sebagai IP pengirim.
- Fungsi `abs_perform` memeriksa IP terhadap tabel `abs_office_ips`. Di luar daftar, absen masuk dan pulang ditolak dan dicatat di `abs_denied`. Izin dan sakit boleh dari mana saja.
- Semua tabel memakai RLS tanpa policy dan hak `anon`/`authenticated` dicabut. Data hanya bisa diakses lewat fungsi, dengan `service_role`.
- Akun terkunci 15 menit setelah 5 kali salah PIN. Satu IP dibatasi 20 percobaan gagal per 15 menit.
- Jam acuan adalah jam server, bukan jam perangkat.

## Pemasangan

1. Jalankan `supabase/migrations/20261112_absensi_ip_kantor.sql` di SQL Editor Supabase.
2. Jalankan juga `20261112_absensi_kehadiran_board.sql`, `20261113_absensi_foto_jadwal_cuti.sql`, lalu `20261113_absensi_board_cuti.sql`.
3. Buat admin pertama dengan kueri di bagian bawah berkas SQL itu. Catat PIN sementaranya, lalu ganti saat login pertama.
4. Deploy Edge Function: `supabase functions deploy absen --no-verify-jwt`.
5. Ubah konstanta `API` di `index.html` ke alamat fungsi di project Supabase Anda: `https://<project-ref>.supabase.co/functions/v1/absen`.
6. Hubungkan repositori ini ke Vercel (framework: Other, tanpa build command). Matikan Vercel Authentication supaya karyawan bisa membuka halaman tanpa akun Vercel.
7. Login sebagai admin dari WiFi kantor, buka tab **Jaringan**, lalu daftarkan jaringan yang sedang dipakai.

## Foto profil dan cuti

- Foto dipotong persegi dan dikecilkan di browser (JPEG sekitar 30 KB), diperiksa lagi oleh Edge Function, lalu disimpan di bucket publik `abs-foto`. Alamat berkas memakai ID karyawan yang acak, dan daftar isi bucket tidak bisa dibuka dari luar.
- Pengajuan cuti berstatus *Menunggu* sampai admin menyetujui. Cuti yang ditambahkan admin langsung disetujui. Hanya hari kerja yang dihitung, dan cuti yang disetujui tidak dihitung sebagai alpa.

## Catatan

- Server hanya mengenali jaringan internet kantor (IP publik), bukan nama WiFi. LAN kabel kantor ikut lolos, kuota seluler ditolak.
- Jika provider mengganti IP kantor, daftarkan IP baru di tab **Jaringan**.
- Perangkat dengan IPv6 mendaftarkan seluruh blok /64. Daftarkan juga IPv4 kantor jika perangkat bisa berpindah antara keduanya.
- Repositori ini tidak berisi kunci atau PIN. Kunci `service_role` hanya ada di lingkungan Edge Function Supabase.

## Deploy otomatis

Project Vercel `absensi-kantor` terhubung ke repositori ini. Setiap push ke branch `main` otomatis ter-deploy ke produksi.

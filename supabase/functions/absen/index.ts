// Absensi: satu pintu untuk semua aksi. Server membaca IP pengirim dari header Cloudflare
// (cf-connecting-ip) yang tidak bisa dipalsukan klien, lalu meneruskannya ke abs_perform.
// Autentikasi memakai kode karyawan + PIN di database, bukan JWT Supabase.
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

const ACTIONS = new Set([
  "ping", "status", "board", "change_pin", "in", "out", "leave",
  "admin_overview", "admin_add_ip", "admin_del_ip", "admin_save_employee",
  "admin_reset_pin", "admin_edit_record", "admin_del_record", "admin_save_settings",
  "schedule", "leave_request", "leave_cancel", "photo_set", "photo_del",
  "admin_leave_list", "admin_leave_decide", "admin_leave_add", "admin_leave_del",
]);

const BUCKET = "abs-foto";
const MAX_FOTO_BYTES = 100 * 1024;
const JPEG_PREFIX = "data:image/jpeg;base64,";

// Mengubah data URL JPEG menjadi byte; null bila bukan JPEG yang wajar.
function decodeJpeg(v: unknown): Uint8Array | null {
  if (typeof v !== "string" || !v.startsWith(JPEG_PREFIX) || v.length > 150000) return null;
  try {
    const bin = atob(v.slice(JPEG_PREFIX.length));
    if (bin.length < 200 || bin.length > MAX_FOTO_BYTES) return null;
    const b = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    return b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff ? b : null;
  } catch {
    return null;
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function clientIp(req: Request): string | null {
  const v = (req.headers.get("cf-connecting-ip") ?? "").trim();
  if (!v) return null;
  if (v.length > 45 || !/^[0-9a-fA-F:.]+$/.test(v)) return null;
  return v;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method === "GET") {
    // Pemeriksaan cepat tanpa login: hanya memberi tahu IP terbaca dan apakah termasuk jaringan kantor.
    const { data, error } = await db.rpc("abs_perform", {
      p_kode: null, p_pin: null, p_action: "ping", p_ip: clientIp(req), p_payload: {},
    });
    if (error) return json({ ok: false, error: "server" }, 500);
    return json(data);
  }
  if (req.method !== "POST") return json({ ok: false, error: "metode" }, 405);

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 200000) return json({ ok: false, error: "terlalu_besar" }, 413);
    body = JSON.parse(raw);
    if (raw.length > 20000 && body.action !== "photo_set") return json({ ok: false, error: "terlalu_besar" }, 413);
  } catch {
    return json({ ok: false, error: "format" }, 400);
  }

  const action = String(body.action ?? "");
  if (!ACTIONS.has(action)) return json({ ok: false, error: "aksi_tidak_dikenal" }, 400);
  const kode = typeof body.kode === "string" ? body.kode.slice(0, 40) : null;
  const pin = typeof body.pin === "string" ? body.pin.slice(0, 40) : null;
  let payload = body.payload && typeof body.payload === "object" && !Array.isArray(body.payload) ? body.payload as Record<string, unknown> : {};

  // Foto: validasi berkas dulu, jangan teruskan gambar ke database.
  let jpeg: Uint8Array | null = null;
  if (action === "photo_set") {
    jpeg = decodeJpeg(payload.image);
    if (!jpeg) return json({ ok: false, error: "foto_tidak_valid" }, 400);
    payload = {};
  }

  const { data, error } = await db.rpc("abs_perform", {
    p_kode: kode, p_pin: pin, p_action: action, p_ip: clientIp(req), p_payload: payload,
  });
  if (error) {
    console.error("abs_perform", error.code, error.message);
    return json({ ok: false, error: "server" }, 500);
  }
  if (action === "photo_set" && data?.ok && jpeg) {
    const up = await db.storage.from(BUCKET).upload(`${data.id}.jpg`, jpeg, {
      contentType: "image/jpeg", upsert: true, cacheControl: "31536000",
    });
    if (up.error) {
      console.error("foto", up.error.message);
      return json({ ok: false, error: "unggah_gagal" }, 500);
    }
  } else if (action === "photo_del" && data?.ok && data.id) {
    await db.storage.from(BUCKET).remove([`${data.id}.jpg`]);
  }
  return json(data);
});

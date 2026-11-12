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
  "ping", "status", "change_pin", "in", "out", "leave",
  "admin_overview", "admin_add_ip", "admin_del_ip", "admin_save_employee",
  "admin_reset_pin", "admin_edit_record", "admin_del_record", "admin_save_settings",
]);

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
    if (raw.length > 20000) return json({ ok: false, error: "terlalu_besar" }, 413);
    body = JSON.parse(raw);
  } catch {
    return json({ ok: false, error: "format" }, 400);
  }

  const action = String(body.action ?? "");
  if (!ACTIONS.has(action)) return json({ ok: false, error: "aksi_tidak_dikenal" }, 400);
  const kode = typeof body.kode === "string" ? body.kode.slice(0, 40) : null;
  const pin = typeof body.pin === "string" ? body.pin.slice(0, 40) : null;
  const payload = body.payload && typeof body.payload === "object" && !Array.isArray(body.payload) ? body.payload : {};

  const { data, error } = await db.rpc("abs_perform", {
    p_kode: kode, p_pin: pin, p_action: action, p_ip: clientIp(req), p_payload: payload,
  });
  if (error) {
    console.error("abs_perform", error.code, error.message);
    return json({ ok: false, error: "server" }, 500);
  }
  return json(data);
});

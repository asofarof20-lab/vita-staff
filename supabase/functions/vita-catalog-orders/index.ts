import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: cors });
const clean = (v: unknown, max = 180) => String(v ?? "").trim().slice(0, max);

async function hash(value: string) {
  const bytes = new TextEncoder().encode(value || "unknown");
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map(x => x.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "Method not allowed" });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply(500, { error: "Сервер не настроен" });

  const db = createClient(url, serviceKey, { auth: { persistSession: false } });
  const catalogDb = createClient(
    "https://yedkbzasynqitvbavwwd.supabase.co",
    "sb_publishable_lV5KW7THtDzy-SN9GTrHLg_z7AFMqUP",
    { auth: { persistSession: false } }
  );

  let body: any;
  try { body = await req.json(); } catch { return reply(400, { error: "Некорректный запрос" }); }
  if (clean(body?.website, 200)) return reply(200, { ok: true });
  const action = clean(body?.action, 20);
  if (action === "stock") {
    const codes = [...new Set((Array.isArray(body?.codes) ? body.codes : [])
      .map((x: unknown) => clean(x, 80)).filter(Boolean))];
    if (!codes.length || codes.length > 250) {
      return reply(400, { error: "Передайте от 1 до 250 кодов товаров" });
    }
    const { data: stockRows, error: stockError } = await db
      .from("vita_stock")
      .select("product_code,quantity")
      .in("product_code", codes);
    if (stockError) return reply(500, { error: "Не удалось получить остатки склада VITANET" });
    return reply(200, { ok: true, stock: stockRows ?? [] });
  }
  if (action !== "order") return reply(400, { error: "Неизвестная операция" });

  const items = Array.isArray(body?.items) ? body.items : [];
  if (!items.length || items.length > 100) return reply(400, { error: "Добавьте товары в заказ" });

  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const ipHash = await hash(ip);
  const { count, error: countError } = await db.from("vita_public_order_rate_limits")
    .select("id", { count: "exact", head: true }).eq("ip_hash", ipHash)
    .gte("created_at", new Date(Date.now() - 60 * 60 * 1000).toISOString());
  if (countError) return reply(500, { error: "Не удалось проверить запрос" });
  if ((count ?? 0) >= 5) return reply(429, { error: "Слишком много заказов. Попробуйте позже." });

  const { error: rateError } = await db.from("vita_public_order_rate_limits").insert({ ip_hash: ipHash });
  if (rateError) return reply(500, { error: "Не удалось зарегистрировать запрос" });
  await db.from("vita_public_order_rate_limits")
    .delete().lt("created_at", new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString());

  const submittedCodes = [...new Set(items.map((x: any) => clean(x?.code, 80)).filter(Boolean))];
  if (!submittedCodes.length) return reply(400, { error: "В заказе нет корректных кодов товаров" });

  const { data: catalogRows, error: catalogError } = await catalogDb.from("products")
    .select("id,name,price").in("id", submittedCodes);
  if (catalogError) return reply(502, { error: "Не удалось проверить товары и цены в каталоге VITA" });

  const catalogByCode = new Map((catalogRows ?? []).map((x: any) => [String(x.id), x]));
  const normalized = [];
  for (const raw of items) {
    const code = clean(raw?.code, 80);
    const product: any = catalogByCode.get(code);
    const quantity = Number(raw?.quantity);
    if (!product || !clean(product.name, 220) ||
        !Number.isFinite(Number(product.price)) || Number(product.price) < 0 ||
        !Number.isFinite(quantity) || quantity <= 0 || quantity > 100000) {
      return reply(400, { error: "В заказе есть неизвестный товар или неверное количество: " + code });
    }
    const price = Number(product.price);
    normalized.push({
      product_code: code,
      product_name: clean(product.name, 220),
      quantity,
      unit_price: price,
      line_total: Math.round(quantity * price * 100) / 100
    });
  }

  // Test-order intake: accept customer orders even while the warehouse is empty.
  // Actual stock is checked and decremented only when an accountant confirms the order.
  const total = Math.round(normalized.reduce((sum, x) => sum + x.line_total, 0) * 100) / 100;
  const note = clean(body?.comment, 1000) || "Заказ из каталога VITA";
  const { data: order, error: orderError } = await db.from("vita_orders")
    .insert({ shop_id: null, status: "new", total, note, source: "catalog" })
    .select("id,order_number").single();
  if (orderError || !order) return reply(500, { error: "Не удалось создать заказ" });

  const { error: itemsError } = await db.from("vita_order_items")
    .insert(normalized.map(x => ({ ...x, order_id: order.id })));
  if (itemsError) {
    await db.from("vita_orders")
      .update({ status: "cancelled", note: "Ошибка записи состава заказа" }).eq("id", order.id);
    return reply(500, { error: "Не удалось сохранить состав заказа" });
  }

  return reply(200, { ok: true, orderId: order.id, orderNumber: order.order_number });
});
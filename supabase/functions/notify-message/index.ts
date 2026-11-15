// 대화 메시지를 보낸 뒤 앱이 부르는 함수: 짝꿍의 기기들로 푸시 알림(Web Push)을 보냄.
// 부른 사람이 그 메시지를 보낸 본인일 때만 보냄.
// 알림용 열쇠(VAPID)는 처음 한 번 만들어 DB의 push_keys 표에 넣어 두고 계속 씀 (비밀 열쇠는 이 함수만 읽음).
// shortcut: 알림은 보낸 사람의 앱이 부탁해야 나감, 놓치는 알림이 생기면 DB 트리거(pg_net)로 옮기기
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SUBJECT = "https://chittang08.github.io/-diary/";
// 기기가 알려 준 주소로 요청을 보내므로, 알려진 푸시 서비스(구글·애플·모질라·윈도우) 주소만 허용
const PUSH_HOSTS = /(^|\.)(googleapis\.com|push\.apple\.com|mozilla\.com|windows\.com)$/;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

let keys: { public_key: string; private_key: string } | null = null;
async function vapidKeys() {
  if (keys) return keys;
  let { data } = await admin.from("push_keys").select("public_key,private_key").maybeSingle();
  if (!data) {
    const k = webpush.generateVAPIDKeys();
    // 동시에 두 번 만들어져도 먼저 들어간 한 쌍만 남김
    await admin.from("push_keys").upsert(
      { id: true, public_key: k.publicKey, private_key: k.privateKey },
      { onConflict: "id", ignoreDuplicates: true },
    );
    ({ data } = await admin.from("push_keys").select("public_key,private_key").single());
  }
  if (!data) throw new Error("push_keys 를 읽지 못했어요");
  return (keys = data);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer /, "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ error: "로그인이 필요해요" }, 401);

    const k = await vapidKeys();
    const { message_id } = await req.json().catch(() => ({}));
    if (!message_id) return json({ publicKey: k.public_key });   // 기기를 등록할 때 쓰는 공개 열쇠

    const { data: msg } = await admin.from("messages").select("couple_id,sender_id,body").eq("id", message_id).maybeSingle();
    if (!msg || msg.sender_id !== user.id) return json({ error: "내가 보낸 메시지가 아니에요" }, 403);

    const { data: others } = await admin.from("couple_members").select("user_id").eq("couple_id", msg.couple_id).neq("user_id", user.id);
    const ids = (others || []).map((m) => m.user_id);
    if (!ids.length) return json({ sent: 0 });

    const [{ data: subs }, { data: prof }] = await Promise.all([
      admin.from("push_subscriptions").select("id,endpoint,p256dh,auth").in("user_id", ids),
      admin.from("profiles").select("nickname").eq("id", user.id).maybeSingle(),
    ]);
    const payload = JSON.stringify({ title: prof?.nickname || "다이어리", body: msg.body.slice(0, 120) });

    let sent = 0;
    await Promise.all((subs || []).map(async (s) => {
      try {
        if (!PUSH_HOSTS.test(new URL(s.endpoint).hostname)) return;
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          payload,
          { vapidDetails: { subject: SUBJECT, publicKey: k.public_key, privateKey: k.private_key }, TTL: 86400, urgency: "high" },
        );
        sent++;
      } catch (e) {
        // 404·410 = 그 기기가 알림을 끊었음 → 목록에서 지움
        if (e?.statusCode === 404 || e?.statusCode === 410) await admin.from("push_subscriptions").delete().eq("id", s.id);
        else console.error("push failed:", e?.statusCode, e?.body || e?.message);
      }
    }));
    return json({ sent });
  } catch (e) {
    console.error("notify-message:", e);
    return json({ error: "알림을 보내지 못했어요" }, 500);
  }
});

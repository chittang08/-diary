// 앱이 부르는 함수: 짝꿍의 기기들로 푸시 알림(Web Push)을 보냄. (새 대화 메시지 / 짝꿍이 초대 코드로 연결됨)
// 메시지 알림은 부른 사람이 그 메시지를 보낸 본인일 때만, 연결 알림은 방금 들어온 사람일 때만 보냄.
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
    const { message_id, joined } = await req.json().catch(() => ({}));
    if (!message_id && !joined) return json({ publicKey: k.public_key });   // 기기를 등록할 때 쓰는 공개 열쇠

    const { data: prof } = await admin.from("profiles").select("nickname").eq("id", user.id).maybeSingle();
    let ids: string[] = [];
    let message: { title: string; body: string; tag: string };   // tag 는 sw.js 가 알림 종류를 구분하는 데 씀
    if (joined) {
      // "짝꿍이 연결됐어요": 방금(10분 안) 초대 코드로 들어온 사람만, 먼저 와 있던 짝꿍에게 보낼 수 있음
      // (아무 때나 반복해서 불러 짝꿍에게 알림을 퍼붓지 못하게)
      const { data: mine } = await admin.from("couple_members").select("couple_id,joined_at").eq("user_id", user.id).maybeSingle();
      if (!mine || Date.now() - Date.parse(mine.joined_at) > 10 * 60 * 1000) return json({ sent: 0 });
      const { data: others } = await admin.from("couple_members").select("user_id,joined_at").eq("couple_id", mine.couple_id).neq("user_id", user.id);
      ids = (others || []).filter((m) => Date.parse(m.joined_at) <= Date.parse(mine.joined_at)).map((m) => m.user_id);
      message = { title: "짝꿍이 연결됐어요 ♥", body: `${prof?.nickname || "짝꿍"}님이 우리 다이어리에 들어왔어요.`, tag: "joined" };
    } else {
      const { data: msg } = await admin.from("messages").select("couple_id,sender_id,body").eq("id", message_id).maybeSingle();
      if (!msg || msg.sender_id !== user.id) return json({ error: "내가 보낸 메시지가 아니에요" }, 403);
      const { data: others } = await admin.from("couple_members").select("user_id").eq("couple_id", msg.couple_id).neq("user_id", user.id);
      ids = (others || []).map((m) => m.user_id);
      message = { title: prof?.nickname || "다이어리", body: msg.body.slice(0, 120), tag: "chat" };
    }
    if (!ids.length) return json({ sent: 0 });

    const { data: subs } = await admin.from("push_subscriptions").select("id,endpoint,p256dh,auth").in("user_id", ids);
    const payload = JSON.stringify(message);

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

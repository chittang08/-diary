// 짝꿍이 초대 코드로 연결되면, 다이어리를 만든 사람의 휴대폰으로 알림(Web Push)을 보낸다.
//
// - 호출: 초대 코드로 연결한 사람의 앱이 연결 직후 sb.functions.invoke('notify-partner') 로 부른다.
// - 보안: 로그인 토큰으로 호출한 사람을 확인하고, 그 사람이 "방금(10분 안) 나중에 들어온 쪽"일 때만 보낸다.
//         (아무나 반복 호출해서 짝꿍에게 알림을 퍼붓지 못하게)
// - 필요한 비밀값(Edge Function secret): VAPID_PRIVATE_KEY
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY 는 Supabase 가 자동으로 넣어준다.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

// 공개키는 공개용이라 코드에 넣어도 됨 (index.html 의 VAPID_PUBLIC_KEY 와 같아야 함)
const VAPID_PUBLIC_KEY =
  "BAhjcELc9YpC6IXe4JlgYYowpbHR0kgfQymyeQ0Or0DaknbCixK8kXC-b_rthyb2ikc1nRVJlAVUStAXuRukd8E";
const VAPID_SUBJECT = "https://chittang08.github.io/-diary/";

// TODO(알림 문구): 문구는 나중에 정하기로 함. 지금은 임시 문구.
function buildMessage(partnerNick: string) {
  return {
    title: "짝꿍이 연결됐어요 ♥",
    body: `${partnerNick}님이 초대 코드로 우리 다이어리에 들어왔어요.`,
  };
}

const JOIN_WINDOW_MS = 10 * 60 * 1000;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const privateKey = Deno.env.get("VAPID_PRIVATE_KEY");
  if (!privateKey) return json({ error: "VAPID_PRIVATE_KEY 가 설정되지 않았어요" }, 500);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // 1) 호출한 사람 확인
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "unauthorized" }, 401);
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  const user = userData?.user;
  if (userErr || !user) return json({ error: "unauthorized" }, 401);

  // 2) 같은 커플의 구성원
  const { data: mine } = await admin
    .from("couple_members").select("couple_id, joined_at")
    .eq("user_id", user.id).maybeSingle();
  if (!mine) return json({ sent: 0, reason: "no couple" });

  const { data: others } = await admin
    .from("couple_members").select("user_id, joined_at")
    .eq("couple_id", mine.couple_id).neq("user_id", user.id);
  const partner = others?.[0];
  if (!partner) return json({ sent: 0, reason: "no partner" });

  // 3) 방금 나중에 들어온 사람만 알림을 보낼 수 있음
  const myJoined = new Date(mine.joined_at).getTime();
  if (myJoined < new Date(partner.joined_at).getTime() || Date.now() - myJoined > JOIN_WINDOW_MS) {
    return json({ sent: 0, reason: "not a fresh join" });
  }

  // 4) 짝꿍 기기로 전송
  const { data: profile } = await admin
    .from("profiles").select("nickname").eq("id", user.id).maybeSingle();
  const message = buildMessage(profile?.nickname || "짝꿍");

  const { data: subs } = await admin
    .from("push_subscriptions").select("id, endpoint, p256dh, auth")
    .eq("user_id", partner.user_id);

  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, privateKey);

  let sent = 0;
  for (const s of subs ?? []) {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify(message),
        { TTL: 60 * 60 * 24 },
      );
      sent++;
    } catch (err) {
      const status = (err as { statusCode?: number }).statusCode;
      // 만료되거나 해지된 구독은 지운다
      if (status === 404 || status === 410) {
        await admin.from("push_subscriptions").delete().eq("id", s.id);
      } else {
        console.error("push send failed", status, err);
      }
    }
  }
  return json({ sent });
});

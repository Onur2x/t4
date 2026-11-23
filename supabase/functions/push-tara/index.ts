// T4 Servis Takip — bildirim tarayicisi
// GitHub Actions her 5 dakikada bir cagirir. Yapilanlar:
//   1) Yeni servis talebi -> yoneticilere
//   2) Talep iptali      -> yoneticilere
//   3) Servis saatinden N dk once -> o kisiye hatirlatma
//   4) Bugun talep acmayanlara -> vardiya kalkisindan N dk once
// Ayni bildirim iki kez gitmesin diye servis_push_log kullanilir.
//
// NOT: isin tamami Deno.serve icinde calisir. Boylece bir hata olursa
// 500 + acik hata mesaji doner ve GitHub Actions logunda gorunur.

import webpush from "npm:web-push@3.6.7";

const SB_URL = Deno.env.get("SUPABASE_URL") || "";
const VAPID_PUB = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const VAPID_PRIV = Deno.env.get("VAPID_PRIVATE_KEY") || "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:servis@example.com";

// servis anahtari: eski SUPABASE_SERVICE_ROLE_KEY ya da yeni SUPABASE_SECRET_KEYS
function servisAnahtari(): string {
  const eski = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (eski) return eski;
  const json = Deno.env.get("SUPABASE_SECRET_KEYS") || "";
  if (!json) return "";
  try {
    const o = JSON.parse(json) as Record<string, string>;
    return o["default"] || (Object.values(o)[0] as string) || "";
  } catch {
    return "";
  }
}

const json = (govde: unknown, kod = 200) =>
  new Response(JSON.stringify(govde), { status: kod, headers: { "Content-Type": "application/json" } });

// ---------- yardimcilar ----------
function istanbul() {
  const now = new Date();
  const f = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Istanbul",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hour12: false
  });
  const p: Record<string, string> = {};
  for (const x of f.formatToParts(now)) p[x.type] = x.value;
  const gun = `${p.year}-${p.month}-${p.day}`;
  const simdi = `${p.hour === "24" ? "00" : p.hour}:${p.minute}`;
  const dk = Number(simdi.slice(0, 2)) * 60 + Number(simdi.slice(3, 5));
  return { gun, simdi, dk, iso: now.toISOString() };
}

function dkYap(s: string) {
  if (!s || !/^\d{1,2}:\d{2}/.test(s)) return 0;
  return Number(s.slice(0, 2)) * 60 + Number(s.slice(3, 5));
}

function saatMetin(d: number) {
  const m = ((d % 1440) + 1440) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
}

type Bildirim = {
  anahtar: string;
  hedef: "admin" | "kisi";
  sicil?: string;
  baslik: string;
  mesaj: string;
  tag?: string;
  url?: string;
};

async function tara() {
  const SRV = servisAnahtari();
  if (!SB_URL) throw new Error("SUPABASE_URL tanimli degil");
  if (!SRV) throw new Error("Supabase servis anahtari yok (SUPABASE_SECRET_KEYS / SUPABASE_SERVICE_ROLE_KEY)");
  if (!VAPID_PUB || !VAPID_PRIV) throw new Error("VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY tanimli degil");
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUB, VAPID_PRIV);

  const sbGet = async (yol: string) => {
    const r = await fetch(`${SB_URL}/rest/v1/${yol}`, {
      headers: { apikey: SRV, Authorization: `Bearer ${SRV}` }
    });
    if (!r.ok) throw new Error(`${yol.split("?")[0]} -> ${r.status} ${await r.text()}`);
    return await r.json();
  };
  const sbPost = async (yol: string, govde: unknown) => {
    const r = await fetch(`${SB_URL}/rest/v1/${yol}`, {
      method: "POST",
      headers: {
        apikey: SRV,
        Authorization: `Bearer ${SRV}`,
        "Content-Type": "application/json",
        Prefer: "resolution=ignore-duplicates,return=minimal"
      },
      body: JSON.stringify(govde)
    });
    if (!r.ok) throw new Error(`${yol.split("?")[0]} -> ${r.status} ${await r.text()}`);
  };
  const sbPatch = async (yol: string, govde: unknown) => {
    const r = await fetch(`${SB_URL}/rest/v1/${yol}`, {
      method: "PATCH",
      headers: {
        apikey: SRV,
        Authorization: `Bearer ${SRV}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal"
      },
      body: JSON.stringify(govde)
    });
    if (!r.ok) throw new Error(`${yol.split("?")[0]} -> ${r.status} ${await r.text()}`);
  };
  const sbDelete = async (yol: string) => {
    await fetch(`${SB_URL}/rest/v1/${yol}`, {
      method: "DELETE",
      headers: { apikey: SRV, Authorization: `Bearer ${SRV}`, Prefer: "return=minimal" }
    }).catch(() => {});
  };

  // ---------- ayarlar ----------
  const ayarListe = await sbGet("servis_ayar?select=anahtar,deger");
  const ayar: Record<string, string> = {};
  for (const a of ayarListe) ayar[a.anahtar] = a.deger;

  if ((ayar["push_aktif"] || "1") !== "1") {
    return { ok: true, atlandi: "Bildirimler kapali (push_aktif=0)" };
  }

  const pushSabah = ayar["push_sabah"] || "07:30";
  const pushAksam = ayar["push_aksam"] || "20:30";
  const pushDk = Number(ayar["push_dk"] || "30");
  const { gun, simdi, dk, iso } = istanbul();

  // ---------- abonelikler ----------
  const aboneler = await sbGet("servis_push_abone?select=sicil,admin,endpoint,p256dh,auth");
  const aboneMap = new Map<string, any[]>();
  for (const a of aboneler) {
    if (!aboneMap.has(a.sicil)) aboneMap.set(a.sicil, []);
    aboneMap.get(a.sicil)!.push(a);
  }
  const adminAbone: any[] = aboneler.filter((a: any) => a.admin === true);

  const bildirimler: Bildirim[] = [];

  // 1) yeni talepler
  let cursor = ayar["push_son_kontrol"] || "";
  if (!cursor) cursor = new Date(Date.now() - 15 * 60000).toISOString();
  const yeni = await sbGet(
    `servis_talep?select=id,sicil,ad,gun,saat,vardiya,yon,durum&created_at=gt.${encodeURIComponent(cursor)}&durum=eq.aktif&order=id.asc&limit=200`
  );
  for (const t of yeni) {
    const vard = t.vardiya === "sabah" ? "Sabah" : "Akşam";
    const yon = t.yon === "karadeniz" ? "KARADENİZ" : "M.SELAM";
    bildirimler.push({
      anahtar: `yeni:${t.id}`,
      hedef: "admin",
      baslik: "🚐 Yeni servis talebi",
      mesaj: `${t.ad} (${t.sicil}) — ${vard} • ${yon} • saat ${String(t.saat).slice(0, 5)}`,
      tag: "t4-yeni",
      url: "./yonetim.html"
    });
  }

  // 2) iptaller
  const iptaller = await sbGet(
    `servis_talep?select=id,sicil,ad,gun,saat,vardiya,yon,guncellendi&durum=eq.iptal&guncellendi=gt.${encodeURIComponent(cursor)}&order=id.asc&limit=200`
  );
  for (const t of iptaller) {
    const vard = t.vardiya === "sabah" ? "Sabah" : "Akşam";
    const yon = t.yon === "karadeniz" ? "KARADENİZ" : "M.SELAM";
    bildirimler.push({
      anahtar: `iptal:${t.id}:${t.guncellendi}`,
      hedef: "admin",
      baslik: "✖️ Servis talebi iptal edildi",
      mesaj: `${t.ad} (${t.sicil}) — ${vard} • ${yon}`,
      tag: "t4-iptal",
      url: "./yonetim.html"
    });
  }

  // 3 + 4) bugunun talepleri
  const bugunTalepler = await sbGet(
    `servis_talep?select=id,sicil,ad,saat,vardiya,yon,durum&gun=eq.${gun}`
  );
  const talepVar = new Set(bugunTalepler.filter((t: any) => t.durum === "aktif").map((t: any) => t.sicil));

  const kalkisOf = (vardiya: string) => dkYap(vardiya === "sabah" ? pushSabah : pushAksam);
  const pencereIcinde = (hedefDk: number) => dk >= hedefDk - 1 && dk <= hedefDk + 5;

  // 3) servis saatinden once hatirlatma
  for (const t of bugunTalepler) {
    if (t.durum !== "aktif") continue;
    const kalkis = kalkisOf(t.vardiya);
    const hedef = kalkis - pushDk;
    if (!pencereIcinde(hedef)) continue;
    const vard = t.vardiya === "sabah" ? "Sabah" : "Akşam";
    const yon = t.yon === "karadeniz" ? "KARADENİZ" : "M.SELAM";
    bildirimler.push({
      anahtar: `rem:${gun}:${t.sicil}`,
      hedef: "kisi",
      sicil: t.sicil,
      baslik: `⏰ Servisine ${pushDk} dk kaldı`,
      mesaj: `${vard} • ${yon} • kalkış ${saatMetin(kalkis)}`,
      tag: "t4-hatirlatma",
      url: "./index.html"
    });
  }

  // 4) bugun talep acmayanlara hatirlatma
  for (const [vardiya, kalkisStr] of [["sabah", pushSabah], ["aksam", pushAksam]] as const) {
    const kalkis = dkYap(kalkisStr);
    const hedef = kalkis - pushDk;
    if (!pencereIcinde(hedef)) continue;
    for (const [sicil, list] of aboneMap) {
      if (list.some((a: any) => a.admin === true)) continue;
      if (talepVar.has(sicil)) continue;
      bildirimler.push({
        anahtar: `nag:${gun}:${vardiya}:${sicil}`,
        hedef: "kisi",
        sicil,
        baslik: "🚐 Servis talebin yok",
        mesaj: `${vardiya === "sabah" ? "Sabah" : "Akşam"} servisi ${kalkisStr}'te kalkıyor. Talep açmayı unutma.`,
        tag: "t4-hatirlatma",
        url: "./index.html"
      });
    }
  }

  // ---------- mukerrer temizligi ----------
  if (!bildirimler.length) {
    await sbPatch(`servis_ayar?anahtar=eq.push_son_kontrol`, { deger: iso, guncellendi: new Date().toISOString() });
    return { ok: true, gun, simdi, adet: 0, mesaj: "Gonderilecek bildirim yok" };
  }

  const anahtarlar = bildirimler.map((b) => b.anahtar);
  const mevcutLog = await sbGet(
    `servis_push_log?select=anahtar&anahtar=in.(${anahtarlar.map((k) => `"${k}"`).join(",")})`
  );
  const gonderildi = new Set(mevcutLog.map((r: any) => r.anahtar));

  // ---------- gonder ----------
  let basarili = 0, hatali = 0, silinen = 0;
  const loglanacak: { anahtar: string }[] = [];

  for (const b of bildirimler) {
    if (gonderildi.has(b.anahtar)) continue;
    const hedefler = b.hedef === "admin" ? adminAbone : (aboneMap.get(b.sicil!) || []);
    if (!hedefler.length) {
      loglanacak.push({ anahtar: b.anahtar });
      continue;
    }
    const payload = JSON.stringify({
      baslik: b.baslik,
      mesaj: b.mesaj,
      tag: b.tag || "t4-bildirim",
      url: b.url || "./index.html"
    });
    let gitti = false;
    for (const a of hedefler) {
      try {
        await webpush.sendNotification(
          { endpoint: a.endpoint, keys: { p256dh: a.p256dh, auth: a.auth } },
          payload,
          { TTL: 3600 }
        );
        gitti = true; basarili++;
      } catch (e: any) {
        hatali++;
        const kod = e?.statusCode;
        if (kod === 404 || kod === 410) {
          await sbDelete(`servis_push_abone?endpoint=eq.${encodeURIComponent(a.endpoint)}`);
          silinen++;
        } else {
          console.log("gonderim hatasi", kod, e?.body || e?.message);
        }
      }
    }
    if (gitti) loglanacak.push({ anahtar: b.anahtar });
  }

  if (loglanacak.length) {
    await sbPost("servis_push_log", loglanacak);
  }
  await sbPatch(`servis_ayar?anahtar=eq.push_son_kontrol`, { deger: iso, guncellendi: new Date().toISOString() });

  // eski log kayitlarini temizle (7 gun)
  const eski = new Date(Date.now() - 7 * 86400000).toISOString();
  await sbDelete(`servis_push_log?created_at=lt.${encodeURIComponent(eski)}`);

  return { ok: true, gun, simdi, adet: bildirimler.length, abone: aboneler.length, basarili, hatali, silinen };
}

// ---------- test bildirimi ----------
async function testGonder(kim: string) {
  const aboneler = await sbGet("servis_push_abone?select=sicil,admin,endpoint,p256dh,auth");
  const hedefler = kim === "hepsi" ? aboneler : aboneler.filter((a: any) => a.admin === true);
  const { simdi } = istanbul();
  const payload = JSON.stringify({
    baslik: "🔔 Test bildirimi",
    mesaj: `Bildirimler çalışıyor. Saat ${simdi}.`,
    tag: "t4-test",
    url: "./index.html"
  });
  let basarili = 0, hatali = 0, silinen = 0;
  const hatalar: string[] = [];
  for (const a of hedefler) {
    try {
      await webpush.sendNotification(
        { endpoint: a.endpoint, keys: { p256dh: a.p256dh, auth: a.auth } },
        payload,
        { TTL: 600 }
      );
      basarili++;
    } catch (e: any) {
      hatali++;
      const kod = e?.statusCode;
      hatalar.push(`${a.sicil}: ${kod || ""} ${String(e?.body || e?.message || e).slice(0, 120)}`);
      if (kod === 404 || kod === 410) {
        await sbDelete(`servis_push_abone?endpoint=eq.${encodeURIComponent(a.endpoint)}`);
        silinen++;
      }
    }
  }
  return { ok: true, test: true, abone: hedefler.length, basarili, hatali, silinen, hatalar };
}

Deno.serve(async (req) => {
  try {
    const govde = await req.json().catch(() => ({}));
    if (govde && govde.test) {
      const sonuc = await testGonder(String(govde.test));
      console.log(JSON.stringify(sonuc));
      return json(sonuc);
    }
    const sonuc = await tara();
    console.log(JSON.stringify(sonuc));
    return json(sonuc);
  } catch (e) {
    const mesaj = String((e as any)?.message || e);
    console.log("HATA", mesaj);
    return json({ ok: false, hata: mesaj }, 500);
  }
});

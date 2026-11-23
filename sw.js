const VERSIYON = "t4-v6";
const KABUK = ["./", "./index.html", "./yonetim.html", "./manifest.webmanifest", "./supabase-config.js", "./push-config.js"];

self.addEventListener("install", (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(VERSIYON).then((c) => c.addAll(KABUK).catch(() => {})));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSIYON).map((k) => caches.delete(k)))).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const u = new URL(e.request.url);
  if (e.request.method !== "GET" || u.origin !== location.origin) return;
  e.respondWith(
    fetch(e.request)
      .then((r) => {
        const k = r.clone();
        caches.open(VERSIYON).then((c) => c.put(e.request, k)).catch(() => {});
        return r;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match("./index.html")))
  );
});

// ---------- Web Push ----------
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { baslik: "Servis Talebi", mesaj: e.data ? e.data.text() : "" }; }
  const baslik = d.baslik || "Servis Talebi";
  const secenek = {
    body: d.mesaj || "",
    icon: "icon-192.png",
    badge: "icon-192.png",
    tag: d.tag || "t4-bildirim",
    renotify: !!d.tag,
    data: { url: d.url || "./index.html" },
    vibrate: [90, 60, 90],
    lang: "tr"
  };
  e.waitUntil(self.registration.showNotification(baslik, secenek));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const hedef = (e.notification.data && e.notification.data.url) || "./index.html";
  e.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) => {
      for (const c of cs) {
        if (c.url.includes(hedef.replace("./", ""))) return c.focus();
      }
      return self.clients.openWindow(hedef);
    })
  );
});

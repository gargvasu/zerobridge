const CACHE = "zb-v2";
const SHELL = ["/", "/manifest.json", "/icons/icon-192.png", "/icons/icon-512.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("push", e => {
  let data = { title: "ZeroBridge", body: "" };
  try { data = e.data.json(); } catch (_) { data.body = e.data ? e.data.text() : ""; }
  e.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      tag: "zb-state",       // replaces previous notification
      renotify: true,
    })
  );
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then(cs => {
      if (cs.length > 0) { cs[0].focus(); return; }
      clients.openWindow("/");
    })
  );
});

self.addEventListener("fetch", e => {
  // Pass through API and WebSocket requests
  const url = new URL(e.request.url);
  if (url.pathname.startsWith("/api/") || url.pathname === "/ws") return;

  e.respondWith(
    fetch(e.request).catch(() =>
      caches.match(e.request).then(r => r || caches.match("/"))
    )
  );
});

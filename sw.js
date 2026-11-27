/* Keeps the app itself on the phone so it opens with no signal.
   Pre-start data is NOT cached here: it lives in Supabase (and a copy in the app's own storage).
   Bump VERSION whenever index.html or the lib files change. */
const VERSION = "site-prestart-v19";
const SHELL = [
  "./", "./index.html", "./manifest.webmanifest",
  "./lib/supabase.js", "./lib/jspdf.umd.min.js", "./lib/qrcode.js",
  "./icons/apple-touch-icon.png", "./icons/icon-192.png", "./icons/icon-512.png", "./icons/favicon-32.png"
];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.hostname.endsWith("supabase.co")) return; // never cache pre-start data or signatures here
  const isPage = req.mode === "navigate";
  const isFont = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
  if (isPage) {
    // Newest page when online, saved copy when not.
    e.respondWith(fetch(req, { cache: "no-store" }).then(r => { const c = r.clone(); caches.open(VERSION).then(x => x.put("./index.html", c)); return r; })
      .catch(() => caches.match("./index.html")));
    return;
  }
  if (url.origin === location.origin || isFont) {
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => {
      if (r.ok || r.type === "opaque") { const c = r.clone(); caches.open(VERSION).then(x => x.put(req, c)); }
      return r;
    })));
  }
});

/* RSA - POS Assistant service worker: keeps the app shell on the phone so it opens instantly and without signal.
   Data calls to Supabase are never cached. Bump VERSION whenever app files change. */
const VERSION = 'rsa-v5';
const SHELL = ['./', 'index.html', 'assets/app.css', 'assets/core.js', 'assets/ui.js', 'assets/staff.js', 'assets/owner.js', 'assets/sections.js', 'assets/admin.js',
  'config.js', 'manifest.webmanifest', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/apple-touch-icon.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;   // Supabase, CDN: straight to network
  if (url.pathname.endsWith('/config.js')) {                                   // connection settings: fresh when online
    e.respondWith(fetch(e.request).then((r) => { const c = r.clone(); caches.open(VERSION).then((ca) => ca.put(e.request, c)); return r; }).catch(() => caches.match(e.request)));
    return;
  }
  // app shell: network first so updates arrive, cache when offline
  e.respondWith(fetch(e.request).then((r) => {
    if (r.ok) { const c = r.clone(); caches.open(VERSION).then((ca) => ca.put(e.request, c)); }
    return r;
  }).catch(() => caches.match(e.request).then((m) => m || caches.match('index.html'))));
});

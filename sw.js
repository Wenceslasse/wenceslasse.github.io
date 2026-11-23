/* Chemin de fer · travail hors ligne
   Garde l'appli, ses polices et la bibliothèque Supabase en cache pour qu'elle
   s'ouvre sans réseau. Les données (numéros, pages) sont gardées par l'appli
   elle-même, sur cet ordinateur ; les requêtes vers Supabase ne passent jamais
   par ce cache. */
const CACHE = "cdf-v1";
const SUPABASE_JS = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.110.2/dist/umd/supabase.min.js";
const SHELL = ["./", "./index.html", "./fonts/Archivo.woff2", "./fonts/Archivo-Italic.woff2"];

self.addEventListener("install", e => {
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    await c.addAll(SHELL).catch(() => {});
    try { const r = await fetch(new Request(SUPABASE_JS, { mode: "cors" })); if (r.ok) await c.put(SUPABASE_JS, r); } catch (_) {}
    self.skipWaiting();
  })());
});
self.addEventListener("activate", e => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
    await self.clients.claim();
  })());
});
self.addEventListener("fetch", e => {
  const req = e.request; if (req.method !== "GET") return;
  const url = new URL(req.url);
  // La bibliothèque Supabase (version figée) : le cache d'abord.
  if (req.url === SUPABASE_JS) {
    e.respondWith(caches.match(SUPABASE_JS).then(r => r || fetch(req).then(res => { const cp = res.clone(); caches.open(CACHE).then(c => c.put(SUPABASE_JS, cp)); return res; })));
    return;
  }
  if (url.origin !== self.location.origin) return; // Supabase, autres sites : jamais en cache
  // L'appli et ses fichiers : le réseau d'abord (pour avoir la dernière version), le cache sans réseau.
  e.respondWith(fetch(req).then(res => {
    if (res.ok) { const cp = res.clone(); caches.open(CACHE).then(c => c.put(req, cp)); }
    return res;
  }).catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match("./index.html"))));
});

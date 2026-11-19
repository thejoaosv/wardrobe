const CACHE = "open-wardrobe-shell-v2";
const IMAGE_CACHE = "wardrobe-images-v2";
const ACTIVE_CACHES = new Set([CACHE, IMAGE_CACHE]);
const MAX_IMAGE_ENTRIES = 800;
const SHELL = ["/", "/manifest.webmanifest", "/icon.svg"];
// Never change once written: built files carry a content hash, and the server stamps new cutouts and try-ons with new names.
const IMMUTABLE = [/^\/assets\//, /^\/_ipx\//, /^\/api\/import\/library\//, /^\/api\/import\/outfits\//];

async function trimImages(cache) {
  const keys = await cache.keys();
  const overflow = keys.length - MAX_IMAGE_ENTRIES;
  if (overflow > 0) await Promise.all(keys.slice(0, overflow).map((request) => cache.delete(request)));
}

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(Promise.all([
    caches.keys().then((keys) => Promise.all(keys.filter((key) => !ACTIVE_CACHES.has(key)).map((key) => caches.delete(key)))),
  ]));
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;

  // Cache first: an immutable file never needs asking for again, and the app still opens with the Mac out of reach.
  if (IMMUTABLE.some((pattern) => pattern.test(url.pathname))) {
    const isAsset = url.pathname.startsWith("/assets/");
    event.respondWith(caches.open(isAsset ? CACHE : IMAGE_CACHE).then(async (cache) => {
      const cached = await cache.match(request);
      if (cached) return cached;
      const response = await fetch(request);
      if (response.ok && !response.redirected) {
        event.waitUntil(cache.put(request, response.clone()).then(() => isAsset ? undefined : trimImages(cache)));
      }
      return response;
    }));
    return;
  }

  if (request.mode === "navigate") {
    event.respondWith(fetch(request).then((response) => {
      const copy = response.clone();
      caches.open(CACHE).then((cache) => cache.put(request, copy));
      return response;
    }).catch(() => caches.match(request).then((cached) => cached || caches.match("/"))));
  }
});

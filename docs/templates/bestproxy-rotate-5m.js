// bestproxy.vn — rotating exit provider (worked example; key removed).
//
// Mirrors the script running on the author's machine. RelayDock resolves this
// per entry (Edge owns the cache), so the job is small and idempotent:
//
//   * reuse the cached proxy while its window is open (no API call at all),
//   * otherwise call get.php exactly once and cache the result.
//
// The window is min(ROTATE_SECONDS, provider lifetime − 60 s) with a 30 s
// floor. get.php answers "Con Ns moi co the doi proxy" when called within
// ~60 s of the previous change, and its success message says when the
// assigned proxy dies ("... die sau 1777s") — so the script stays one minute
// ahead of both. The 5-minute cap keeps the exit IP rotating on roughly that
// cadence instead of waiting out the provider's full endpoint lifetime.
//
// Runtime notes: the `cache` object persists across resolves as JSON (this
// script keeps `url` + `expiresAt` in it), fetched with standard `fetch`, and
// has standard JS globals (Date, URLSearchParams). Replace KEY before use.
const KEY = "<provider key>";
const NHAMANG = "random";        // "viettel" | "fpt" | "vnpt" | "" (empty = random)
const TINHTHANH = "0";           // "0" = random, or a province code from the provider docs
const ROTATE_SECONDS = 5 * 60;   // rotate the exit at most every 5 minutes

// Window still open: reuse the cached proxy (no API call, no rotation churn).
if (cache.url && cache.expiresAt && Date.now() < cache.expiresAt) {
  return cache.url;
}

const params = new URLSearchParams();
params.set("key", KEY);
if (NHAMANG) params.set("nhamang", NHAMANG);
if (TINHTHANH) params.set("tinhthanh", TINHTHANH);
// If the key needs an IP whitelist, uncomment these two lines:
// const myIP = await (await fetch("https://api.ipify.org")).text();
// params.set("whitelist", myIP.trim());

const data = await (await fetch("https://proxyxoay.shop/api/get.php?" + params.toString())).json();
if (data.status !== 100) {
  throw new Error("bestproxy: " + (data.message || "status " + data.status));
}

// "42.117.243.215:10836::" → http://[user:pass@]host:port
const [host, port, user, pass] = String(data.proxyhttp).split(":");
cache.url = "http://" + (user ? user + ":" + (pass || "") + "@" : "") + host + ":" + port;

// Cache until min(rotation cap, 60 s before the proxy dies), floor 30 s:
// "proxy nay se die sau 1777s" → 1717 s of life, capped to the 300 s rotation.
const life = /(\d+)s/.exec(data.message || "");
const seconds = life ? Math.max(parseInt(life[1], 10) - 60, 30) : 600;
cache.expiresAt = Date.now() + Math.min(seconds, ROTATE_SECONDS) * 1000;

return cache.url;

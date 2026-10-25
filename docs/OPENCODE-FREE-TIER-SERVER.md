# OpenCode free-tier limits — server-side enforcement

**Status:** research note — describes OpenCode Zen, not RelayDock behavior.

**Date:** 2026-10-25

**Scope:** how the OpenCode Zen inference service decides that a free-model request has hit
`FreeUsageLimitError`, what it counts, how it identifies the caller, and when the limit resets.
Paid rate limits and OpenCode Go quotas are covered only where they differ from the free lane.

**Method:** live HTTP probes against `https://opencode.ai/inference`, the public inference
OpenAPI document, the public OpenCode client source, the last public snapshot of the Zen proxy
route, and statements from OpenCode maintainers in GitHub issues. Exact thresholds are not
published and are not in the public source.

---

## TL;DR

- The check is **server-side**, in the Zen inference service, before the request is forwarded to
  an upstream provider. The client only maps the returned error.
- The baseline free limit is a **successful-request counter per IP per UTC day**, with a
  long-lived per-IP reputation counter. A new IP gets a higher first-day allowance.
- `retry-after` is the number of seconds until **00:00 UTC**, not a rolling 24-hour window.
- The current public contract exposes a richer `cap` / `trace` model: request, session, monthly,
  carry-over, rotation, session-velocity, TLS fingerprint, classifier and experiment signals.
  The exact algorithm and thresholds are closed-source.
- Free models share a bucket by default; the contract also allows a per-model bucket.
- The free lane is separate from OpenCode Go. A Go subscriber can still be blocked on free
  models, and `/go/v1/usage` only reports Go meters.
- There is no public endpoint for free-tier usage or reset time. Official support points to the
  Console, but users report the Console only exposes Go meters; the free counter is not visible
  through the public API.

---

## 1. Where the check happens

All inference traffic goes through Cloudflare to the Zen service:

```text
OpenCode client
  -> https://opencode.ai/inference/<protocol>/...
  -> Cloudflare (cf-ray, cf-placement)
  -> Zen inference service
  -> upstream model provider
```

Evidence:

- Responses carry `server: cloudflare`, `cf-ray`, `cf-placement`, and `x-opencode-log-id`.
- `GET https://opencode.ai/inference/health` returns `{"status":"ok","latency":5}`.
- The public OpenAPI document is `https://opencode.ai/inference/openapi.json`.
- The open-source OpenCode repository contains the client and Console marketing code, but **not**
  the inference-server implementation. The last public snapshot of the Zen proxy route exists in
  forks of the pre-removal tree (`v2.0.0`); it is useful evidence for the baseline, but it is
  not the current deployed source.

The client-side mapping is small and does not make the decision:

- `packages/core/src/session/to-session-error.ts` turns a 429 whose body contains
  `FreeUsageLimitError` into `provider.free-limit`.
- `packages/ai/src/provider-error.ts` includes `FreeUsageLimitError` in `QUOTA_CODES`, so it is
  classified as `QuotaExceeded` and is **not retried**.
- `packages/ai/src/route/executor.ts` parses `retry-after` / `retry-after-ms` into
  `retryAfterMs`.

---

## 2. Request flow in the server

The public snapshot of `handler.ts` shows the order. The comments are additions; the code is
condensed.

```ts
const rawIp = input.request.headers.get("x-real-ip") ?? ""
const ip = rawIp.includes(":") ? rawIp.split(":").slice(0, 4).join(":") : rawIp

const rawZenApiKey = opts.parseApiKey(input.request.headers)
const zenApiKey = rawZenApiKey === "public" ? undefined : rawZenApiKey

const modelInfo = validateModel(zenData, model)          // unknown model -> 400
const trialLimiter = createTrialLimiter(modelInfo.trialProvider, ip)
const trialProviders = await trialLimiter?.check()

const rateLimiter = modelInfo.allowAnonymous
  ? createIpRateLimiter(modelInfo.id, modelInfo.rateLimit, ip, input.request)
  : createKeyRateLimiter(modelInfo.id, modelInfo.rateLimit, zenApiKey, input.request)

await rateLimiter?.check()                               // over -> 429 FreeUsageLimitError
const authInfo = await authenticate(modelInfo, zenApiKey)
const billingSource = validateBilling(authInfo, modelInfo)

const res = await forwardToProvider(...)
await rateLimiter?.track()                               // increment after success
await trackUsage(...)
```

Consequences:

1. **Model validation happens before the free-limit check.** A non-existent model returns
   `400 Model is unavailable`, not `429`. This was confirmed live.
2. **The free-model IP limiter runs before authentication.** `Bearer public` is treated as
   anonymous (`zenApiKey = undefined`). A valid API key does not bypass the IP check for a free
   model in this snapshot.
3. **The counter increments after a successful response**, not when the request is admitted.
   Failed or rejected requests do not consume the daily counter.
4. **The caller is identified from the edge IP and optional headers**, not from the request body:
   - `x-real-ip` (IPv6 is truncated to `/64`)
   - `authorization` / `api-key` / `x-api-key` / `x-goog-api-key`
   - `x-opencode-session`, `x-opencode-project`, `x-opencode-client`
   - `x-session-affinity`, `x-opencode-request`, `x-opencode-metadata`
   - `user-agent`

The client sends the session/project/client headers in
`packages/core/src/session/model-request.ts`:

```ts
"x-opencode-session-id": session.id,
"x-session-affinity": affinity,
"x-opencode-project": session.projectID,
"x-opencode-session": affinity,
"x-opencode-client": app.name,
"User-Agent": App.useragent(app),
```

The server logs these as metrics (`session`, `request`, `client`, `user_agent`, `model.variant`,
`model.tier`, `source`, `provider`, token and cost fields). That telemetry is also the input for
the anti-abuse signals described in §5.

---

## 3. Baseline free-limit algorithm

The public snapshot implements the free limit in
`packages/console/app/src/routes/zen/util/ipRateLimiter.ts`:

```ts
const retryAfter = Math.ceil((86_400_000 - (now % 86_400_000)) / 1000)
const isNew = lifetimeCount < dailyLimit * 7

if ((isNew && dailyCount >= dailyLimit * 2) ||
    (!isNew && dailyCount >= dailyLimit))
  throw new FreeUsageLimitError(message, retryAfter)
```

Tracking:

```ts
pipeline.incr(dailyKey)
pipeline.expire(dailyKey, retryAfter)
if (isNew) pipeline.incr(lifetimeKey)
await pipeline.exec()
```

### Keys

| Key | Meaning | Expiry |
| --- | --- | --- |
| `ip:<ip>:<YYYYMMDD>` | successful requests for this IP on this UTC day | `retryAfter` seconds (expires at 00:00 UTC) |
| `ip:<ip>` | lifetime successful requests for this IP | none |

### Limits

- `dailyLimit` comes from the Cloudflare secret `ZEN_LIMITS.free.dailyRequests`, with
  `ZEN_LIMITS.free.dailyRequestsFallback` as the fallback.
- The values are not in the repository and are not published. Maintainers say the limits change
  with capacity.
- A "new" IP (`lifetime < dailyLimit * 7`) is allowed up to **2x** the daily limit on its first
  day. An established IP gets **1x** per day.
- The lifetime key has no TTL. It is incremented only while the IP is still "new" (`isNew`), so it
  preserves the IP's accumulated count across days and stops growing once the IP is established.

### Per-model vs shared

```ts
const dailyInterval = rateLimit
  ? `${buildYYYYMMDD(now)}${modelId.substring(0, 2)}`
  : buildYYYYMMDD(now)
const isDefaultModel = headersExist && !rateLimit
```

- Free models without a custom `rateLimit` share the plain `YYYYMMDD` bucket.
- A model with a custom `rateLimit` gets a bucket prefixed by the first two characters of its
  model ID, and uses that custom limit.
- The live OpenAPI contract reflects both cases with `cap.scope: "shared" | "model"`.

### Client-header check

The snapshot contains a disabled check:

```ts
// temporarily disable check headers
//const headersExist = Object.entries(limits.checkHeaders).every(...)
const headersExist = true
```

The intent was to give clients that send the expected headers the normal limit and everyone else
a lower fallback limit. In this snapshot the check is disabled, so every client gets the same
limit. The current contract adds `client-tls` as a cap reason, which suggests the deployed service
now uses a stronger client-identity signal.

### Trial token limiter

`trialLimiter.ts` is a separate mechanism. It counts **tokens** per IP against
`ZEN_LIMITS.free.promoTokens`:

```ts
const usage =
  usageInfo.inputTokens +
  usageInfo.outputTokens +
  (usageInfo.reasoningTokens ?? 0) +
  (usageInfo.cacheReadTokens ?? 0) +
  (usageInfo.cacheWrite5mTokens ?? 0) +
  (usageInfo.cacheWrite1hTokens ?? 0)
```

It does **not** throw `FreeUsageLimitError` by itself. It decides whether trial providers keep
priority in provider selection. When the IP is over the promo-token allowance, the request is no
longer routed to the trial provider; the normal provider selection applies. This matters for
models whose free capacity comes from a trial provider.

### Key limiter (paid/key models)

For models that are not anonymous, the snapshot uses
`packages/console/app/src/routes/zen/util/keyRateLimiter.ts`:

```ts
const LIMIT = rateLimit ?? 1000
const interval = `${modelId.substring(0, 27)}-${yyyyMMddHHmm}`
if (count >= LIMIT) throw new RateLimitError(message, 60)
```

That is a **per-key, per-model, per-minute** limit, returning `RateLimit.Exceeded` with
`retry-after: 60`, not `FreeUsageLimitError`. It is a different error class and a different
client classification (`provider.rate-limit`, retryable).

### Go quota

Go subscription checks are in `handler.ts` / `subscription.ts`:

- rolling window (`rollingLimit`, `rollingWindow` hours)
- weekly limit (`fixedLimit`, UTC week bounds)
- monthly limit (`monthlyLimit`, billing-cycle bounds)

They throw `GoUsageLimitError` with `workspace` and `limitName` (`"5 hour"`, `"weekly"`,
`"monthly"`) and a `retryAfter` to the end of the relevant window. The public
`GET /go/v1/usage` endpoint returns those three meters:

```json
{
  "usage": {
    "rolling": { "status": "ok", "percent": 0, "resetsAt": "..." },
    "weekly":  { "status": "ok", "percent": 0, "resetsAt": "..." },
    "monthly": { "status": "ok", "percent": 0, "resetsAt": "..." }
  }
}
```

`/go/v1/usage` requires a real key or org header. Without one it returns
`401 {"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}`. There is no
`/v1/usage` free-tier equivalent in the public spec.

---

## 4. Live probe evidence (2026-10-25)

### 4.1 Free model, anonymous

Request:

```bash
curl -i https://opencode.ai/inference/openai/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer public' \
  -d '{"model":"deepseek-v4.1-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":1}'
```

Response (11:46:21 UTC):

```http
HTTP/2 429
date: Sun, 25 Oct 2026 11:46:21 GMT
content-type: application/json
retry-after: 44019
x-opencode-log-id: 01a172e2-1333-7616-b46d-aa172b2b7267
server: cloudflare
```

```json
{
  "type": "error",
  "error": {
    "type": "FreeUsageLimitError",
    "message": "Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"
  }
}
```

`11:46:21 + 44,019s = 24:00:00 UTC`. The value is exactly the number of seconds until the next
UTC midnight. Later probes returned `44005`, `44004`, and `43999`, i.e. the same countdown.

### 4.2 Other observations

| Probe | Result | What it shows |
| --- | --- | --- |
| `deepseek-v4.1-flash-free`, `big-pickle`, `glm-5.3-flash-free` within the same minute | all `429` | these free models share a bucket |
| no `Authorization` header | `429`, same body | the gate is IP/network based, not key based |
| `Authorization: Bearer public` | `429`, same body | `public` is anonymous |
| invalid model `definitely-not-a-real-model` | `400` `Upstream request failed: Model is unavailable.` | model validation runs before the free-limit check |
| any 429 | no `x-ratelimit-remaining`, no `x-ratelimit-reset` | the only reset signal is `retry-after` |
| any 429 | no `cap` field | the deployed response is the legacy shape; `cap` is in the spec but not observed |
| `GET /go/v1/usage` without auth | `401 AuthError` | Go usage is not public |
| `GET /go/v1/usage` with `Bearer public` | `401 AuthError` | `public` is not a Go credential |

The 429 body does **not** match the OpenAPI schema exactly:

- The schema names the type `RateLimit.FreeUsageLimitError`; the wire body says
  `FreeUsageLimitError`.
- The schema puts `retryAfter` and `cap` inside the error object; the wire response puts
  `retry-after` in the header and omits both fields.
- The schema marks `cap` as required; the observed response has no `cap`.

Treat the spec as the current **contract** and the probe as the current **deployment**. They are
close, but not identical.

---

## 5. Current public contract: `cap` and `trace`

The 429 response is a union:

```text
RateLimit.FreeUsageLimitError | RateLimit.Exceeded
```

`RateLimit.Exceeded` is the ordinary rate limit:

```json
{ "type": "RateLimit.Exceeded", "message": "...", "retryAfter": 60 }
```

`RateLimit.FreeUsageLimitError` adds a schema-required `cap` object and an optional `trace`
object. The live deployment returned neither, so the following describes the contract and the
server's vocabulary, not a response you should expect from every 429.

### 5.1 `cap`

```json
{
  "reason": "requests",
  "scope": "shared",
  "limit": 100,
  "usage": 100,
  "fingerprint": "…"
}
```

- `reason`: why the cap fired.
- `scope`: `shared` (across free models) or `model` (one model).
- `limit` / `usage`: numeric values. The unit depends on the reason; the schema does not say
  whether it is requests, sessions, tokens, or money.
- `fingerprint`: optional string, likely a hashed IP/device/environment identity.

`reason` enum, grouped by what the name implies:

| Group | Values | Interpretation |
| --- | --- | --- |
| Volume / window | `requests`, `sessions`, `range`, `monthly`, `allowance` | request count, session count, time range, monthly allowance, generic allowance |
| Carry-over | `carry`, `prompt-carry`, `workdir-carry` | usage or identity carried across buckets, prompts, or working directories |
| Evasion | `rotation`, `rotation-48`, `session-spread`, `short-sessions`, `session-velocity`, `session-no-env`, `env-rotation`, `env-quota` | key/account rotation, many short sessions, session spreading, fast session creation, missing environment signals, environment rotation |
| Identity / trust | `client-tls`, `session-age`, `active-hours`, `classifier`, `access`, `blocked` | TLS fingerprint, new session/account, unusual activity hours, classifier score, access policy, hard block |
| Experiment | `probe` | request is part of a probe/experiment arm |

These are **name-based interpretations**. The exact predicates, weights, and thresholds are not
public. Do not treat the table as a specification of the algorithm.

### 5.2 `trace`

```json
{
  "cohort": "…",
  "arm": "probe",
  "probe": true,
  "enforce": false,
  "signals": ["retry-pace", "session-hop", "snap-back", "model-switch"],
  "allowance": 100,
  "score": 0.8,
  "paintCapped": true,
  "paintSkipped": 0,
  "wouldMax": "requests",
  "paintBusyIP": false
}
```

| Field | Type | Interpretation |
| --- | --- | --- |
| `cohort` | string / null | experiment cohort |
| `arm` | `"probe"` / `"control"` / null | A/B arm |
| `probe` | boolean | request is in a probe arm |
| `enforce` | boolean | whether the cap is actually enforced |
| `signals` | array | observed evasion behaviour: `retry-pace`, `session-hop`, `snap-back`, `model-switch` |
| `allowance` | number / null | allowance used for this decision |
| `score` | number / null | classifier/risk score |
| `paintCapped` | boolean / null | likely "paint" a cap without enforcing it |
| `paintSkipped` | number / null | likely how much painting was skipped |
| `wouldMax` | string / null | the cap that would have applied |
| `paintBusyIP` | boolean / null | likely restrict painting to busy IPs |

`newIPSkipped` is a separate top-level field:

```json
{ "newIPSkipped": "log" }
```

It is `"log"` or `"enforce"` and null when absent. The name suggests that requests from new IPs
can be exempted from a cap, with either logging or enforcement of the exemption.

### 5.3 What this means

The deployed service is not just a single request counter. The contract exposes:

- multiple cap dimensions (requests, sessions, monthly, carry-over),
- behavioural evasion signals (session hopping, model switching, retry pacing),
- client/environment identity (TLS, fingerprint, environment rotation, session age),
- an experiment layer (`probe`/`control`, `enforce`, `paint*`).

The baseline IP counter from §3 is still the simplest confirmed mechanism. The `cap` vocabulary is
evidence that the current server layers more checks on top. It does **not** prove that every 429
uses all of them.

---

## 6. What is counted?

There are at least three accounting modes in the public snapshot:

| Mode | Scope | Unit | When it matters |
| --- | --- | --- | --- |
| IP daily limiter | free models, anonymous or authenticated | successful HTTP requests | the normal free-model gate |
| Trial limiter | IP + trial provider | tokens (input + output + reasoning + cache read/write) | decides whether the trial provider keeps priority |
| Key limiter | API key + model + minute | requests | paid/key models, returns `RateLimit.Exceeded` |

The current contract's `limit` / `usage` numbers do not carry a unit. The `reason` value is the
only hint. A `requests` cap is probably request-counted; a `monthly` or `allowance` cap may be
token- or cost-based. There is no public statement that resolves this.

Observed behaviour from issue reports:

- Long sessions with a large context fail while a new, small session succeeds.
- The same account and model can pass and fail seconds apart as context size changes.
- Compacting a session or starting a new one can make requests pass again.

These reports are consistent with **request-count accounting plus many agent steps** (each step
is a request) and with **token-based trial accounting**. They do not prove a single unit. The
maintainers have not published the rule.

---

## 7. Scope and reset

### Scope

- **IP / network:** confirmed for anonymous free requests. The server reads `x-real-ip` and
  truncates IPv6 to `/64`, so a whole IPv6 prefix shares a bucket.
- **Account / workspace:** official support statements say the limit is applied per account and
  per network. The public snapshot only shows the IP limiter for free models, so account-level
  checks are likely a later addition (the `fingerprint` and `scope` fields are consistent with
  that).
- **Shared vs per-model:** the three free models tested returned 429 within the same minute, so at least
  that group shares a bucket. The contract allows `scope: "model"` for models with a custom
  `rateLimit`.
- **Go is separate:** a Go subscription does not exempt the free lane. The free counter and the Go
  rolling/weekly/monthly meters are different systems.

### Reset

- The baseline reset is **00:00 UTC daily**, not 24 hours after the first request.
- `retry-after` is the seconds-to-midnight value and is also used as the TTL of the daily Redis
  key.
- The client's `GO_UPSELL_WINDOW = 86_400_000` in
  `packages/app/src/session/usage-exceeded-dialogs.tsx` is a dialog-suppression window, not the
  quota window.

### Dynamic limits

`Subscription.getLimits()` parses a Cloudflare secret JSON (`ZEN_LIMITS`) with this shape:

```ts
free: {
  promoTokens: number
  dailyRequests: number
  dailyRequestsFallback: number
  checkHeaders: Record<string, string>
}
```

Because the values live in a secret and maintainers say they change with capacity, there is no
stable number to document. Any specific "N requests per day" claim should be treated as a
snapshot, not a contract.

### RelayDock behavior (implementation note)

RelayDock does not try to evade the free lane. It treats a reported limit as account/network-wide
and pauses only the proxy entry that actually carried the request.

- **Cooldown:** the loopback OpenCode plugin forwards `FreeUsageLimitError` to Edge, which writes
  a deadline to `free-usage-limits.json`. A deadline never shortens an existing one.
- **Reset time:** a structured `retryAfter` / `retryAfterMs` / `resetAtMs` from the provider wins.
  Without one, the fallback is the number of seconds until the next **00:00 UTC**, matching the
  server behaviour in §3. A structured zero or past reset clamps to one second rather than
  quarantining the proxy for a day.
- **Tunnel attribution:** a report is matched to the tunnel from the same OpenCode pid on the same
  Edge port that most recently delivered response bytes (within 120 seconds), not to the newest
  tunnel. If two different entries delivered bytes within two seconds of each other, the report is
  ambiguous and RelayDock pauses nothing. A missed pause is preferable to quarantining a healthy
  proxy.
- **Recovery:** the row shows the absolute local reset time. **Retry now** sends one small probe
  through that proxy; only a pass clears the cooldown. An automatic recheck runs at most once per
  cooldown, in the 15 minutes before the reset (polled every 10 minutes), so it does not create a
  steady retry pace while hours remain.
- **Shared warning:** when two or more enabled entries have reset deadlines within 30 minutes of each
  other, the pool banner says so. Switching proxies, accounts, or sessions does not move the bucket when
  the limit is tied to the same network/account; only waiting for the reset (or changing the
  egress network) does.

---

## 8. Why a user can be limited early

In rough order of likelihood:

1. **Shared IP / NAT / VPN / datacenter egress.** Another user on the same IP already exhausted
   the bucket. Changing networks can change the result.
2. **Lifetime counter.** An IP with `lifetime >= dailyLimit * 7` no longer gets the 2x first-day
   allowance.
3. **IPv6 `/64` aggregation.** Many devices in the same prefix share one bucket.
4. **Many agent steps.** Each tool call / model step is a separate HTTP request. A long session
   can burn the daily request budget quickly.
5. **Free lane is separate from Go.** Paying for Go does not restore free-model quota.
6. **Anti-abuse signals.** Session velocity, session spreading, key rotation, TLS fingerprint,
   environment rotation, classifier score, or an experiment arm can block before the simple
   request counter is exhausted.

The client cannot explain which one fired. It only receives `429` and `retry-after`; the
`x-opencode-log-id` header is the identifier support needs to trace the decision.

---

## 9. How to reproduce / inspect

Minimal free-model probe (consumes one request if quota is available):

```bash
curl -i https://opencode.ai/inference/openai/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer public' \
  -d '{"model":"deepseek-v4.1-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":1}'
```

Useful checks:

- `retry-after`: seconds until the reset (00:00 UTC for the daily free cap).
- `x-opencode-log-id`: request identifier for support.
- `400 Model is unavailable`: model validation happened before the quota check.
- `429 FreeUsageLimitError` with `retry-after`: free lane.
- `429 RateLimit.Exceeded` with `retry-after: 60`: key/model per-minute limit, not the free cap.
- `429` with `metadata.limitName`: Go quota (`5 hour`, `weekly`, `monthly`).
- `GET /go/v1/usage`: Go meters only; requires auth.
- `GET /v1/models`: live model catalog; free models are the ones whose ID ends in `-free` plus
  `big-pickle` at the time of writing, but the authoritative client definition is
  `providerID === "opencode"` (or `opencode-go`) with no input price.

There is no public free-usage endpoint. Official support points to the Console for usage and
reset time, but at least one user report says the Console only shows Go meters and dollar cost
(#58205). Treat the free counter as server-side only unless the Console shows it for your
workspace.

---

## 10. Confirmed vs inferred

| Claim | Status | Evidence |
| --- | --- | --- |
| Free limit is enforced server-side | Confirmed | 429 from the service; maintainer statements; client only maps the error |
| Model validation precedes the free check | Confirmed | invalid model returned 400, not 429 |
| `public` is treated as anonymous | Confirmed | `handler.ts` sets `zenApiKey = undefined` for `"public"`; live probe |
| Free requests are gated by IP/network | Confirmed for anonymous | no-auth and `Bearer public` both 429; `x-real-ip` / IPv6 `/64` in code |
| Daily reset at 00:00 UTC | Confirmed | `retry-after: 44019` at 11:46:21 UTC; maintainer comment in #58900 |
| The baseline counter counts successful requests | Confirmed in public snapshot | `incr` in `track()`, called after the upstream response |
| New IPs get 2x the daily limit | Confirmed in public snapshot | `isNew && dailyCount >= dailyLimit * 2` |
| Trial limiter counts tokens per IP | Confirmed in public snapshot | `promoTokens` and token sum in `trialLimiter.ts` |
| Free models share a bucket by default | Confirmed for tested models; contract allows per-model | three models 429 within the same minute; `scope: "shared" \| "model"` |
| Limit is per account **and** network | Stated by maintainers; not visible in public snapshot | #58805, #58205 |
| Current server uses `cap.reason` / `trace` | Confirmed in public spec; not observed in live 429 | OpenAPI schemas |
| Exact meaning of `paint*` / `wouldMax` | Inferred from names | schema field names only |
| Exact daily limit, window, and unit | Unknown / unpublished | `ZEN_LIMITS` secret; maintainer statements |
| Public snapshot equals deployed code | Not confirmed | snapshot is `v2.0.0`; the route is absent from `v2.1.4` and later |

---

## 11. Limitations

- The inference server is closed-source. The public snapshot is the last visible version of the
  Zen proxy route, not the current deployment.
- The live OpenAPI document is newer than the observed wire response: it describes `cap` and
  `trace`, but the 429 we received did not include them. The spec is a contract, not a packet
  capture.
- The live probes came from one IP at one time. They prove that IP was over the bucket; they do
  not reveal the global limit or the behaviour of other networks.
- Issue reports are user anecdotes, not controlled experiments. They are useful for symptoms,
  not for exact thresholds.
- No Console account, server logs, or database access was available. The `x-opencode-log-id`
  values are the only server-side trace identifiers captured.

---

## 12. References

Unless stated otherwise, repository paths in this section are relative to the OpenCode repository,
not RelayDock.

### Live endpoints

- `https://opencode.ai/inference/openapi.json` — public inference OpenAPI
- `https://opencode.ai/inference/v1/models` — live model catalog
- `https://opencode.ai/inference/health` — health probe
- `https://opencode.ai/inference/go/v1/usage` — Go usage (auth required)

### OpenCode docs and client source

- `services/www/src/docs/content/console/api/inference.mdx` — free chat models can be called
  without an API key
- `services/www/src/docs/content/console/models.mdx` — free model list and endpoints
- `services/www/src/docs/content/console/go.mdx` — Go limits and the free-model fallback
- `services/www/src/docs/content/models.mdx` — free model definition
- `packages/core/src/plugin/provider/opencode.ts` — signed-out `public` key and paid-model gating
- `packages/core/src/session/to-session-error.ts` — `FreeUsageLimitError` → `provider.free-limit`
- `packages/ai/src/provider-error.ts` — `QUOTA_CODES` and quota classification
- `packages/ai/src/route/executor.ts` — `retry-after` parsing
- `packages/core/src/session/model-request.ts` — session/project/client headers
- `packages/app/src/session/usage-exceeded-dialogs.tsx` — free-limit dialog and 24h upsell window
- `packages/tui/src/routes/session/index.tsx` — TUI free-limit notice

### Public snapshot of the Zen proxy (pre-removal)

- `packages/console/app/src/routes/zen/util/ipRateLimiter.ts`
- `packages/console/app/src/routes/zen/util/trialLimiter.ts`
- `packages/console/app/src/routes/zen/util/keyRateLimiter.ts`
- `packages/console/app/src/routes/zen/util/handler.ts`
- `packages/console/app/src/routes/zen/util/error.ts`
- `packages/console/core/src/subscription.ts`

Example public fork:
`https://github.com/sure-scale/doc-haus/blob/dochaus/packages/console/app/src/routes/zen/util/ipRateLimiter.ts`

### GitHub issues

- #58900 — `FreeUsageLimitError`, `Retry-After` points to 00:00 UTC
- #58805 — limit on home fiber but not mobile data; per account and per network
- #58751 — free limit depends on request size / long sessions
- #55816 — request to publish the free limit; maintainer says limits change with capacity
- #57540 — request to document free-tier accounting (unit, window, scope)
- #58205 — 429 with no free usage in the window; reset time not exposed

---

## 13. One-paragraph summary

The Zen inference service checks free-model requests before forwarding them. It identifies the
caller from the edge IP (IPv6 `/64`), optional key, and session/project/client headers, validates
the model, chooses an IP limiter for anonymous free models or a key limiter for paid models,
checks Redis/DB counters, and returns `429 FreeUsageLimitError` with `retry-after` when the
counter is exhausted. The baseline free counter is a successful-request count per IP per UTC day,
reset at 00:00 UTC, with a 2x first-day allowance for new IPs and a long-lived lifetime counter.
The current contract layers additional caps and anti-abuse signals on top: sessions, monthly and
carry-over allowances, key/environment rotation, session velocity/spreading, TLS fingerprint,
classifier, and experiment arms. Exact thresholds, units, and the full algorithm are
closed-source and unpublished; `retry-after` and `x-opencode-log-id` are the only actionable
signals the client receives.

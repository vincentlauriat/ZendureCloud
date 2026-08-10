# ZendureCloud — Architecture

> Source of truth. French mirror: `ARCHITECTURE.md` — keep both in sync in the same turn.
> Last updated: 2026-08-10 (v0.3.0 + energy history layer).

## Overview

Native macOS app (SwiftUI, macOS 14+, `@Observable`) that connects to the Zendure Cloud and
displays everything it publishes about the account's devices. Exploratory by design: raw data
is always reachable (raw properties table, MQTT console), derived metrics are computed
in-app. Two **fully isolated** cloud access paths coexist:

```
                          ┌──────────────────────────────────────────────┐
                          │                  AppModel                    │
                          │   @Observable @MainActor — UI aggregates     │
                          └──────┬──────────────────────────┬────────────┘
                                 │                          │
                 ┌───────────────┴───────────┐   ┌──────────┴─────────────┐
                 │       CloudService        │   │     HistoryService     │
                 │ (real-time, Cloud Key)    │   │ (history, app account) │
                 └──┬─────────┬──────────────┘   └──────────┬─────────────┘
                    │         │                             │
        ┌───────────┴──┐   ┌──┴─────────┐        ┌──────────┴─────────────┐
        │  ZendureAPI  │   │ MQTTClient │        │     ZendureAppAPI      │
        │ deviceList   │   │ MQTT 3.1.1 │        │ login → serverNodeUrl  │
        │ (SHA1 sign)  │   │ NWConnect. │        │ tdengine energy/electr.│
        └──────────────┘   └────────────┘        └────────────────────────┘
              HTTP              MQTT                        HTTP
        {apiUrl}/api/ha   mqtt broker (clear)      {serverNodeUrl}/tdengine
```

## Path 1 — real time (Cloud Key)

1. **`CloudKey`** decodes the base64 token from the Zendure app → `apiUrl` (region embedded)
   + `appKey`. Stored in Keychain (`cloudKey`).
2. **`ZendureAPI`** signs `POST {apiUrl}/api/ha/deviceList` (SHA1, constant key, headers
   `timestamp`/`nonce`/`clientid: zenHa`/`sign`) → device list + MQTT credentials.
   This is the ONLY endpoint of this auth family.
3. **`MQTTClient`** — minimal in-house MQTT 3.1.1 over `NWConnection` (zero dependencies).
   Pure static packet encode/decode (`MQTTPacket`) for unit testing.
4. **`CloudService`** orchestrates: phases (`notConfigured/fetchingDevices/connectingMQTT/
   live/failed`), subscribes to both topic forms (`/pk/dk/#` and `iot/pk/dk/#`), merges
   partial `properties/report` payloads into per-device `DeviceState`, polls
   `properties/read getAll` every 60 s (on `pollQueue`, NEVER `stateQueue` — deadlock,
   see 2026-08-09), reconnects via full re-login after 15 s.
   Every frame (in/out) is also forwarded to `onMQTTLog` **before any filtering** → MQTT
   console.

## Path 2 — energy history (app account, private API)

Only known way to read history (up to 365 days): the mobile app's private API. See
`ZENDURE_API_RESEARCH.md` § Historisation for the full protocol research.

1. **`ZendureAppAPI`** (pure request builders, testable):
   - `POST {base}/auth/app/token` with account e-mail/password (Basic constant header,
     app-spoofing headers `appVersion: 4.3.1`) → `accessToken` (used as `Blade-Auth:
     bearer …`) + **`serverNodeUrl`** (regional TDengine node). `base` reuses the Cloud
     Key's `apiUrl` region, falling back to `https://app.zendure.tech/eu`.
   - `POST {base}/productModule/device/queryDeviceListByConsumerId` → app-side device
     `id`s (≠ deviceKey), matched to Cloud-Key devices **by serial number** (name as
     fallback).
   - `POST {serverNodeUrl}/tdengine/device/solarFlow/energy` with
     `{aceId:"", deviceId, beginDate, endDate, zone, type}` — `type: 0` + same dates =
     one day; `type: ""` + empty dates = lifetime totals. Numeric fields are extracted
     tolerantly; `energyVos`/`data` chart series exist in responses but are not parsed yet.
2. **`HistoryService`** (`@MainActor @Observable`): credentials in Keychain
   (`appAccount`/`appPassword`), lazy login, work plan = missing days only (disk cache
   `Application Support/ZendureCloud/history/<deviceKey>.json`; only *today* is
   re-fetched), sequential fetch with 150 ms throttle (private API, fragile cloud),
   phases (`notConfigured/idle/connecting/loading(done,total)/failed`).
   All calls go through a single `send()` that records every HTTP exchange
   (`ZendureAppAPI.Exchange`, password redacted, bounded to 50) into a debug journal
   shown in the History window, and turns non-2xx statuses into readable errors
   (status + response-body excerpt).

## Models

- **`DeviceState`** — merged per-device state. Partial reports are merged field by field,
  never replaced. Unit traps centralized here (tenths of kelvin, hundredths of volt,
  signed Int16 `batcur`, `socSet` auto-scale, sentinel 59940). Holds raw properties
  (timestamped) for the raw table, `EnergyCounters` (session Wh integration, power ×
  elapsed time between reports, gaps > 10 min skipped), and derived values
  (`totalCapacityKwh`, `availableKwh`, `estimatedRemainMinutes`).
- **`BatteryCatalog`** — pack model + nominal kWh from serial-number prefix (Zendure-HA
  `get_battery_type` mapping).
- **`PropertyCatalog`** — French documentation of ~65 cloud properties (raw table).
- **`MQTTLogEntry`** — one frame (direction, topic, payload, pretty JSON) for the console.
- **`EnergyDay` / `EnergyMetricCatalog` / `HistoryCache`** — one history day (raw
  key→value fields, list varies by productType), French labels, JSON disk cache.

## UI (scenes in `ZendureCloudApp`)

| Scene | id | Content |
|---|---|---|
| Window “Tableau de bord” | `dashboard` | header (aggregates + buttons) + per-device masonry (Overview, Power, Energy session, Packs, Info) + full-width raw properties table |
| Window “Historique” | `history` | credentials card or range picker (7/30/90/365 d) + Swift Charts daily bars + lifetime totals |
| Window “Console MQTT” | `mqtt-console` | all frames, filter, pause, clear, expandable pretty JSON |
| MenuBarExtra | — | average SOC label + per-device dropdown |
| Settings | — | refresh interval, appearance, menu bar, account |

Every scene re-injects `.environment(model)` (scenes don't share environment) and calls
`model.start()` in `.onAppear` (idempotent) — MacInside pattern.

## Storage

| What | Where |
|---|---|
| Cloud Key token | Keychain `cloudKey` |
| App account e-mail / password | Keychain `appAccount` / `appPassword` |
| History day cache | `Application Support/ZendureCloud/history/<deviceKey>.json` |
| Settings | `UserDefaults` via `AppSettings` |
| Sparkle EdDSA private key | login keychain, account `ZendureCloud` — **never regenerate** |

## Threading

- `CloudService` runs off-main: `stateQueue` (state sync), `pollQueue` (timer),
  MQTT internal queue. All callbacks re-dispatch to main. Poll timer must not run on
  `stateQueue` (sync-in-sync deadlock, fixed 2026-08-09).
- `HistoryService` and `AppModel` are `@MainActor`; network awaits suspend off-main via
  URLSession.

## Releases

`Scripts/release.sh <version>` : xcodegen → Release build (`CODE_SIGNING_ALLOWED=NO`) →
staging `ditto --noextattr` → codesign deepest-first (Sparkle XPC → framework → app,
Hardened Runtime, timestamp retries) → DMG → notarytool (`AppliMacVincentGithub`) →
staple → Sparkle EdDSA sign → `appcast.xml` regenerated (sparkle:version =
CFBundleVersion). Publish: `gh release create` + push appcast on `main`.
Independent post-release checks: `spctl`, `stapler validate`, `codesign --verify`.

## Non-contractual API warning

All cloud APIs used here are private and may break at any time. Auth layers are isolated
(`CloudKey`/`ZendureAPI` vs `ZendureAppAPI`) so a protocol change stays contained. The
local zenSDK transport (mDNS + HTTP, see research doc § 4) remains the planned fallback.

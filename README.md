# ZendureCloud

Native macOS dashboard for the Zendure Cloud — connects to your Zendure account and shows everything the cloud publishes about your devices (SolarFlow, Hyper, AIO…), in the visual style of MacInside.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange) ![Release](https://img.shields.io/github/v/release/vincentlauriat/ZendureCloud)

> **Exploratory project.** This tool exists purely to explore the (undocumented, non-contractual) Zendure Cloud API. It is not affiliated with, endorsed by, or supported by Zendure. Use at your own risk — the API may change or break at any time.

## Features

| Feature | Status |
|---|---|
| Cloud Key authentication (token from the Zendure app, stored in Keychain) | ✅ |
| Device list via signed `api/ha/deviceList` call | ✅ |
| Real-time data over MQTT (own minimal MQTT 3.1.1 client, zero dependencies) | ✅ |
| Dashboard window — masonry of cards per device | ✅ |
| SOC circular gauge, power flows (solar/home/grid/battery), sparklines | ✅ |
| Battery packs detail (per-pack SOC, temperature, voltage, current) | ✅ |
| Pack identification by serial prefix (model + nominal kWh, à la Zendure-HA) | ✅ |
| Derived metrics: available kWh, cell ΔV, estimated runtime, bypass state | ✅ |
| Session energy counters (solar/home/grid/charge/discharge + roundtrip efficiency) | ✅ |
| **Raw properties browser** — every key the cloud publishes, filterable | ✅ |
| **MQTT console** — every raw frame in/out (all topics), filter, pause, pretty JSON | ✅ |
| Menu bar extra (average SOC label + per-device dropdown) | ✅ |
| Fallback poll `properties/read getAll` (configurable interval) | ✅ |
| Auto-reconnect with full re-login on MQTT drop | ✅ |
| Auto-update (Sparkle 2, EdDSA-signed) | ✅ |
| Write support (outputLimit, acMode…) | ⬜ roadmap |
| Local zenSDK transport as fallback | ⬜ roadmap |

## Install

Download the latest notarized DMG from [Releases](https://github.com/vincentlauriat/ZendureCloud/releases), open it and drag **ZendureCloud.app** to `/Applications`. The app checks for updates automatically via Sparkle (menu **ZendureCloud → Rechercher les mises à jour…**).

## Setup

1. In the Zendure mobile app: **Profile → Authorization Cloud Key** (or **Settings → Developer**, depending on the app version), main account, copy the token.
2. Launch ZendureCloud, paste the token in the setup card (or Settings → Compte).
3. The token decodes to `apiUrl.appKey` — the region (EU/global) is embedded in the URL, nothing to choose.

The token is stored only in the macOS Keychain (`fr.lauriat.ZendureCloud`).

## Build

```bash
xcodegen generate
xcodebuild -scheme ZendureCloud -configuration Debug build
xcodebuild -scheme ZendureCloud test        # 26 unit tests
```

Single external dependency: [Sparkle 2](https://sparkle-project.org) for auto-updates (SPM). Everything else is system frameworks — Network.framework for MQTT, CryptoKit for the SHA1 request signature, Swift Charts for sparklines.

Releases are built with `./Scripts/release.sh <version>` (Developer ID signing, notarization, stapling, Sparkle EdDSA signature, `appcast.xml`).

## Project layout

```
Sources/
  ZendureCloudApp.swift       @main — Window + MenuBarExtra + Settings
  AppModel.swift              @Observable bridge CloudService → SwiftUI
  Formatters.swift            W / kWh / V / °C / min formatting
  SafeDelta.swift             protected counter subtraction (from MacInside)
  Models/
    ZendureDevice.swift       deviceList response models
    DeviceState.swift         merged per-device state + raw properties + packData + energy counters
    BatteryCatalog.swift      pack model/kWh from serial prefix (Zendure-HA mapping)
  Services/
    CloudKey.swift            base64 token → apiUrl + appKey
    ZendureAPI.swift          signed deviceList request (SHA1)
    MQTTClient.swift          minimal MQTT 3.1.1 over NWConnection
    CloudService.swift        orchestration: login → devices → MQTT → merge
    KeychainHelper.swift
  Views/                      DashboardView (masonry), DeviceCards, Components/
  MenuBar/                    label + dropdown
  Settings/                   AppSettings (@Observable + UserDefaults), SettingsView
Tests/                        CloudKey, signature, MQTT packets, state merging
```

## Protocol notes

- `POST {apiUrl}/api/ha/deviceList` signed with SHA1(`secret + sortedParams + secret`), headers `timestamp`/`nonce`/`clientid: zenHa`/`sign` — same protocol as the official Zendure Home Assistant integration.
- MQTT topics subscribed per device: `/{productKey}/{deviceKey}/#` **and** `iot/{productKey}/{deviceKey}/#` (firmwares differ).
- Reports are partial → merged field by field; `packData` keyed by pack serial.
- Unit traps handled: temperatures in tenths of kelvin, voltages in hundredths of volt, `batcur` as signed Int16 / 10, `socSet`/`minSoc` auto-scale, `remainOutTime` 59940 = unavailable.

These are non-contractual APIs — the auth layer is isolated in `CloudKey`/`ZendureAPI` so a protocol change stays contained.

## Roadmap

- [ ] Write support (output limit, AC mode, SOC range) via `properties/write`
- [ ] Local zenSDK transport (mDNS discovery) as offline fallback
- [ ] Energy history persistence + daily charts
- [x] Sparkle auto-update + notarized DMG release
- [ ] Widget

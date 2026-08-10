# ZendureCloud — Architecture

> Miroir français de `ARCHITECTURE_EN.md` (source de vérité) — maintenir les deux dans le
> même tour. Dernière mise à jour : 2026-08-10 (v0.3.0 + couche historique d'énergie).

## Vue d'ensemble

App macOS native (SwiftUI, macOS 14+, `@Observable`) qui se connecte au Cloud Zendure et
affiche tout ce qu'il publie sur les appareils du compte. Exploratoire par conception : la
donnée brute reste toujours accessible (table des propriétés brutes, console MQTT), les
métriques dérivées sont calculées dans l'app. Deux chemins d'accès au cloud **totalement
isolés** coexistent :

```
                          ┌──────────────────────────────────────────────┐
                          │                  AppModel                    │
                          │  @Observable @MainActor — agrégats pour l'UI │
                          └──────┬──────────────────────────┬────────────┘
                                 │                          │
                 ┌───────────────┴───────────┐   ┌──────────┴─────────────┐
                 │       CloudService        │   │     HistoryService     │
                 │ (temps réel, Cloud Key)   │   │ (historique, cpte app) │
                 └──┬─────────┬──────────────┘   └──────────┬─────────────┘
                    │         │                             │
        ┌───────────┴──┐   ┌──┴─────────┐        ┌──────────┴─────────────┐
        │  ZendureAPI  │   │ MQTTClient │        │     ZendureAppAPI      │
        │ deviceList   │   │ MQTT 3.1.1 │        │ login → serverNodeUrl  │
        │ (sign SHA1)  │   │ NWConnect. │        │ tdengine energy/electr.│
        └──────────────┘   └────────────┘        └────────────────────────┘
              HTTP              MQTT                        HTTP
        {apiUrl}/api/ha   broker mqtt (clair)      {serverNodeUrl}/tdengine
```

## Chemin 1 — temps réel (Cloud Key)

1. **`CloudKey`** décode le jeton base64 de l'app Zendure → `apiUrl` (région incluse)
   + `appKey`. Stocké dans le trousseau (`cloudKey`).
2. **`ZendureAPI`** signe `POST {apiUrl}/api/ha/deviceList` (SHA1, clé constante, en-têtes
   `timestamp`/`nonce`/`clientid: zenHa`/`sign`) → liste d'appareils + credentials MQTT.
   C'est le SEUL endpoint de cette famille d'auth.
3. **`MQTTClient`** — client MQTT 3.1.1 minimal maison sur `NWConnection` (zéro dépendance).
   Encodage/décodage des paquets en statiques purs (`MQTTPacket`), testés unitairement.
4. **`CloudService`** orchestre : phases (`notConfigured/fetchingDevices/connectingMQTT/
   live/failed`), abonnement aux deux formes de topic (`/pk/dk/#` et `iot/pk/dk/#`), fusion
   des rapports partiels `properties/report` dans un `DeviceState` par appareil, poll
   `properties/read getAll` toutes les 60 s (sur `pollQueue`, JAMAIS `stateQueue` —
   deadlock, cf. 2026-08-09), reconnexion par re-login complet après 15 s.
   Chaque trame (entrante/sortante) part aussi vers `onMQTTLog` **avant tout filtrage** →
   console MQTT.

## Chemin 2 — historique d'énergie (compte app, API privée)

Seule voie connue pour lire l'historique (jusqu'à 365 jours) : l'API privée de l'app
mobile. Voir `ZENDURE_API_RESEARCH.md` § Historisation pour la recherche protocolaire.

1. **`ZendureAppAPI`** (constructeurs de requêtes purs, testables) :
   - `POST {base}/auth/app/token` avec e-mail/mot de passe du compte (en-tête Basic
     constant, en-têtes d'imitation de l'app `appVersion: 4.3.1`) → `accessToken`
     (utilisé en `Blade-Auth: bearer …`) + **`serverNodeUrl`** (nœud TDengine régional).
     `base` réutilise la région de l'`apiUrl` du Cloud Key, repli
     `https://app.zendure.tech/eu`.
   - `POST {base}/productModule/device/queryDeviceListByConsumerId` → les `id` côté app
     (≠ deviceKey), rapprochés des appareils Cloud Key **par numéro de série** (nom en
     repli).
   - `POST {serverNodeUrl}/tdengine/device/solarFlow/energy` avec
     `{aceId:"", deviceId, beginDate, endDate, zone, type}` — `type: 0` + dates égales =
     un jour ; `type: ""` + dates vides = totaux vie entière. Les champs numériques sont
     extraits avec tolérance ; les séries `energyVos`/`data` existent dans les réponses
     mais ne sont pas encore parsées.
2. **`HistoryService`** (`@MainActor @Observable`) : identifiants dans le trousseau
   (`appAccount`/`appPassword`), login paresseux, plan de travail = jours manquants
   uniquement (cache disque `Application Support/ZendureCloud/history/<deviceKey>.json` ;
   seul *aujourd'hui* est re-téléchargé), récupération séquentielle avec pause de 150 ms
   (API privée, cloud fragile), phases (`notConfigured/idle/connecting/loading(done,total)/
   failed`).
   Tous les appels passent par un `send()` unique qui journalise chaque échange HTTP
   (`ZendureAppAPI.Exchange`, mot de passe masqué, borné à 50) dans un journal de
   débogage affiché dans la fenêtre Historique, et transforme les statuts non-2xx en
   erreurs lisibles (statut + extrait du corps de réponse).

## Modèles

- **`DeviceState`** — état fusionné par appareil. Les rapports partiels sont fusionnés
  champ par champ, jamais remplacés. Pièges d'unités centralisés ici (dixièmes de kelvin,
  centièmes de volt, `batcur` Int16 signé, auto-échelle `socSet`, sentinelle 59940).
  Porte les propriétés brutes (horodatées) pour la table, les `EnergyCounters`
  (intégration Wh de session, puissance × temps écoulé entre rapports, trous > 10 min
  ignorés) et les valeurs dérivées (`totalCapacityKwh`, `availableKwh`,
  `estimatedRemainMinutes`).
- **`BatteryCatalog`** — modèle de pack + kWh nominal depuis le préfixe du numéro de série
  (mapping `get_battery_type` de Zendure-HA).
- **`PropertyCatalog`** — documentation française d'~65 propriétés cloud (table brute).
- **`MQTTLogEntry`** — une trame (direction, topic, payload, JSON indenté) pour la console.
- **`EnergyDay` / `EnergyMetricCatalog` / `HistoryCache`** — un jour d'historique (champs
  clé→valeur bruts, liste variable selon productType), libellés français, cache disque JSON.

## UI (scènes dans `ZendureCloudApp`)

| Scène | id | Contenu |
|---|---|---|
| Fenêtre « Tableau de bord » | `dashboard` | header (agrégats + boutons) + masonry par appareil (Vue d'ensemble, Puissance, Énergie session, Batteries, Infos) + table des propriétés brutes en pleine largeur |
| Fenêtre « Historique » | `history` | carte identifiants ou sélecteur de période (7/30/90/365 j) + barres quotidiennes Swift Charts + totaux vie entière |
| Fenêtre « Console MQTT » | `mqtt-console` | toutes les trames, filtre, pause, vider, JSON indenté dépliable |
| MenuBarExtra | — | libellé SOC moyen + menu par appareil |
| Réglages | — | intervalle de poll, apparence, barre de menus, compte |

Chaque scène ré-injecte `.environment(model)` (les scènes ne partagent pas l'environnement)
et appelle `model.start()` en `.onAppear` (idempotent) — pattern MacInside.

## Stockage

| Quoi | Où |
|---|---|
| Jeton Cloud Key | Trousseau `cloudKey` |
| E-mail / mot de passe du compte app | Trousseau `appAccount` / `appPassword` |
| Cache des jours d'historique | `Application Support/ZendureCloud/history/<deviceKey>.json` |
| Réglages | `UserDefaults` via `AppSettings` |
| Clé privée EdDSA Sparkle | trousseau de connexion, compte `ZendureCloud` — **ne jamais régénérer** |

## Threading

- `CloudService` tourne hors main : `stateQueue` (sync d'état), `pollQueue` (timer),
  queue interne MQTT. Tous les callbacks re-dispatchent sur le main. Le timer de poll ne
  doit pas tourner sur `stateQueue` (deadlock sync-dans-sync, corrigé le 2026-08-09).
- `HistoryService` et `AppModel` sont `@MainActor` ; les await réseau suspendent via
  URLSession hors main.

## Releases

`Scripts/release.sh <version>` : xcodegen → build Release (`CODE_SIGNING_ALLOWED=NO`) →
staging `ditto --noextattr` → codesign du plus imbriqué vers l'extérieur (XPC Sparkle →
framework → app, Hardened Runtime, retries de timestamp) → DMG → notarytool
(`AppliMacVincentGithub`) → staple → signature EdDSA Sparkle → `appcast.xml` régénéré
(sparkle:version = CFBundleVersion). Publication : `gh release create` + push de
l'appcast sur `main`. Vérifications indépendantes post-release : `spctl`,
`stapler validate`, `codesign --verify`.

## Avertissement APIs non contractuelles

Toutes les APIs cloud utilisées ici sont privées et peuvent casser à tout moment. Les
couches d'auth sont isolées (`CloudKey`/`ZendureAPI` vs `ZendureAppAPI`) pour qu'un
changement de protocole reste contenu. Le transport local zenSDK (mDNS + HTTP, cf. doc de
recherche § 4) reste le repli prévu.

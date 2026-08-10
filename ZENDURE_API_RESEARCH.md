# Accès programmatique au Cloud Zendure — rapport technique

> Recherche menée le 8 août 2026 à partir du code source et de la documentation publique.
> **Aucun appel réseau n'a été effectué vers les serveurs Zendure** : tous les formats décrits
> proviennent de la lecture de code et restent à confirmer au premier essai réel.

## Résumé exécutif

Le login email/mot de passe historique n'est plus le chemin à implémenter. Les deux
intégrations maintenues aujourd'hui — celle officielle de Zendure pour Home Assistant et
l'adaptateur ioBroker — utilisent un jeton **« Authorization Cloud Key »** que l'utilisateur
copie depuis l'app mobile, puis un endpoint `POST {apiUrl}/api/ha/deviceList` signé en SHA1.
Les deux bases de code contiennent la **même clé de signature en dur** (`C*dafwArEOXK`), ce qui
confirme qu'il s'agit du protocole courant et non d'une particularité de fork.

| Méthode | Statut | Usage recommandé |
|---|---|---|
| 1. Cloud Key + `/api/ha/deviceList` + MQTT | Active, maintenue | **Chemin principal du client Swift** |
| 2. API développeur `developer/api/apply` | Active, lecture seule | Repli / prototypage rapide |
| 3. Login email/mot de passe | Historique, non vérifiée | À ne pas implémenter |
| 4. zenSDK local (HTTP + mDNS) | Active, modèles récents | Second transport, sans dépendance cloud |

---

## Méthode 1 — Cloud Key + `/api/ha/deviceList` (recommandée)

### 1.1 Obtention du jeton par l'utilisateur

Dans l'app mobile Zendure : onglet **Profile** → entrée **« Authorization Cloud Key »**
(située entre « Green forest » et « More services »).

Le message d'erreur de l'intégration officielle mentionne pour sa part un chemin différent —
*« Copy the Home Assistant token again from the Zendure app (Settings, Developer) »*. Le libellé
varie selon la version de l'app : **les instructions utilisateur doivent citer les deux
emplacements**. Le jeton doit provenir du **compte principal** auquel les appareils sont
rattachés (un compte secondaire partagé ne renvoie aucun appareil).

### 1.2 Décodage du jeton

Le jeton est une chaîne base64. Décodé en UTF-8, il donne `"<apiUrl>.<appKey>"`, à découper
**sur le dernier point** :

```swift
guard let data = Data(base64Encoded: token),
      let decoded = String(data: data, encoding: .utf8),
      let lastDot = decoded.lastIndex(of: ".") else { throw ZendureError.malformedToken }

let apiUrl = String(decoded[decoded.startIndex..<lastDot])
let appKey = String(decoded[decoded.index(after: lastDot)...])
```

`apiUrl` **encode déjà la région** (EU ou global) : aucun choix de région à exposer dans
l'interface, et aucune URL à coder en dur.

### 1.3 Requête

```http
POST {apiUrl}/api/ha/deviceList
Content-Type: application/json
timestamp: <epoch secondes>
nonce: <entier aléatoire 10000-99999, en chaîne>
clientid: zenHa
sign: <SHA1 hexadécimal MAJUSCULES>

{"appKey": "<appKey>"}
```

Construction de `sign` :

1. Rassembler `appKey`, `nonce`, `timestamp` ;
2. trier **par nom de clé, ordre croissant** → donne l'ordre `appKey`, `nonce`, `timestamp` ;
3. concaténer `clé + valeur` sans séparateur → `appKey<v>nonce<v>timestamp<v>` ;
4. encadrer avec la clé constante : `"C*dafwArEOXK" + bodyStr + "C*dafwArEOXK"` ;
5. SHA1 en UTF-8, rendu **hexadécimal en majuscules**.

Le `timestamp` de l'en-tête et celui entrant dans la signature doivent être **identiques**, en
secondes (pas en millisecondes).

### 1.4 Réponse

```json
{
  "code": 200,
  "success": true,
  "msg": "Successful operation",
  "data": {
    "deviceList": [
      {
        "deviceKey":    "…",
        "productKey":   "…",
        "productModel": "SolarFlow 800",
        "deviceName":   "…",
        "snNumber":     "…",
        "ip":           ""
      }
    ],
    "mqtt": { "clientId": "…", "url": "host[:port]", "username": "…", "password": "…" }
  }
}
```

`deviceKey` et `productKey` composent les topics MQTT. `ip` est souvent vide ; l'intégration
officielle retombe alors sur `zendure-{productModel sans espaces}-{snNumber}.local`.

Validations à faire, dans cet ordre — ce sont les cinq cas d'erreur distingués par
l'intégration officielle :

| Contrôle | Erreur correspondante |
|---|---|
| Jeton décodable et contenant un point | jeton malformé |
| Requête aboutie | API injoignable |
| `code == 200 && success == true` | API rejette la requête (`msg` à afficher) |
| `deviceList` non vide | compte ou région sans appareil |
| `mqtt` non vide | MQTT non activé sur le compte |

### 1.5 Connexion MQTT

- Hôte et port : champ `url`, à découper sur le **dernier** `:` ; port `1883` par défaut.
- `clientId`, `username`, `password` : ceux renvoyés par l'API.
- Version du protocole : l'intégration Home Assistant négocie en **MQTT 3.1**, ioBroker en
  **MQTT 5**. En Swift (CocoaMQTT), partir sur 3.1.1 et basculer en 3.1 en cas de refus.
- Connexion **en clair**, sans TLS.

### 1.6 Topics

S'abonner aux **deux formes** — les firmwares publient sur l'une ou l'autre :

```
/{productKey}/{deviceKey}/#
iot/{productKey}/{deviceKey}/#
```

Parsing : découper le topic en **4 segments au maximum** (`split(separator: "/", maxSplits: 3)`).
L'index 2 donne le `deviceKey`, l'index 3 le sous-topic. Cela fonctionne pour les deux formes,
la variante avec `/` initial produisant simplement un premier segment vide.

Sous-topics entrants :

| Sous-topic | Contenu |
|---|---|
| `properties/report` | flux principal : `{"properties": {…}, "packData": [.…]}` |
| `properties/energy` | signale que le HEMS est actif |
| `register/replay` | à ré-publier avec payload vide, **QoS 1, retain = true** |
| `time-sync`, `event/device`, `event/error`, `log`, `config` | annexes |

Topics sortants :

```
iot/{productKey}/{deviceKey}/properties/read     → {"properties": ["getAll"]}
iot/{productKey}/{deviceKey}/properties/write    → {"properties": {"outputLimit": 300}}
iot/{productKey}/{deviceKey}/function/invoke
```

Chaque payload publié doit porter en plus `deviceId` (égal au `deviceKey`), `messageId`
(compteur incrémental) et `timestamp` (epoch secondes). **Pour `function/invoke`, le payload
contient à la fois `deviceKey` et `deviceId`**, tous deux égaux à l'identifiant de l'appareil —
envoyer les deux.

Publier `properties/read` avec `{"properties":["getAll"]}` force un rafraîchissement complet ;
c'est ainsi que l'intégration officielle effectue son poll de sécurité toutes les 60 secondes.

### 1.7 Astuce annexe : mot de passe MQTT dérivé

Un appareil peut se connecter au broker (cloud comme local) avec `username = deviceKey` et
`password = MD5(deviceKey).hex().uppercased()[8..<24]` — les 16 caractères du milieu du hash.
Utilisé par l'intégration officielle pour republier vers le cloud, et documenté indépendamment
par un projet tiers. Utile en secours, à ne pas mettre sur le chemin principal.

### Sources

- <https://github.com/Zendure/Zendure-HA/blob/master/custom_components/zendure_ha/api.py> (fonction `ApiHA`)
- <https://github.com/Zendure/Zendure-HA/blob/master/custom_components/zendure_ha/device.py> (topics, publication)
- <https://github.com/nograx/ioBroker.zendure-solarflow/blob/main/src/services/zenWebService.ts>
- <https://github.com/Zendure/Zendure-HA/wiki/Installation>
- <https://github.com/tb1337/zendure-solarflow-mqtt-pwd-gen>

---

## Méthode 2 — API développeur officielle

Toujours documentée et utilisée par evcc. Plus simple, mais flux MQTT en lecture seule et
numéro de série requis.

```http
POST https://app.zendure.tech/v2/developer/api/apply     (global)
POST https://app.zendure.tech/eu/developer/api/apply     (Europe)
Content-Type: application/json

{"snNumber": "VU5D99F74021B04", "account": "vous@exemple.com"}
```

```json
{"code":200,"success":true,
 "data":{"appKey":"zendure","secret":"zendureSecret","mqttUrl":"mqtt.zen-iot.com","port":1883},
 "msg":"Successful operation"}
```

Connexion MQTT en clair sur `tcp://{mqttUrl}:{port}`, `username = appKey`, `password = secret`,
abonnement à **`{appKey}/#`** — forme de topic totalement différente de la méthode 1, à ne pas
mélanger.

Limites connues : l'appareil doit être appairé au compte, et le **couple région/compte doit
correspondre** — appeler l'endpoint global avec un compte en région Allemagne renvoie
`code 400 « Please bind the device first »`. Des utilisateurs signalent aussi des hôtes
régionaux (`mqtt-eu.zen-iot.com`) devenus muets (non vérifié).

### Sources

- <https://github.com/Zendure/developer-device-data-report>
- <https://github.com/Zendure/developer-device-data-report/issues/30>
- <https://github.com/evcc-io/evcc/tree/master/meter/zendure>

---

## Méthode 3 — Login email/mot de passe (historique, non vérifiée)

```http
POST https://app.zendure.tech/v2/auth/app/token
Content-Type: application/json
Authorization: Basic Q29uc3VtZXJBcHA6NX4qUmRuTnJATWg0WjEyMw==
Blade-Auth: bearer (null)
appVersion: 4.3.1
User-Agent: Zendure/4.3.1 (iPhone; iOS 14.4.2; Scale/3.00)

{"password":"…","account":"email","appId":"121c83f761305d6cf7e",
 "appType":"iOS","grantType":"password","tenantId":""}
```

Le `data.accessToken` obtenu se replace dans l'en-tête `Blade-Auth: bearer <token>` pour :

- `POST /v2/productModule/device/queryDeviceListByConsumerId` (liste des appareils, sans corps)
- `POST /v2/device/solarFlow/detail` avec `{"deviceId": "…"}`

**Statut : aucune intégration maintenue ne l'utilise encore, et elle n'a pas été testée.**
À traiter comme non fiable.

Source : <https://github.com/reinhard-brandstaedter/solarflow-statuspage/blob/master/src/zenapi/ZendureAPI.py>

---

## Méthode 4 — Contrôle local zenSDK (sans cloud)

Découverte par **mDNS** : service `_zendure._tcp`, nom
`Zendure-<Modèle>-<12 derniers caractères du MAC>`. Sur macOS, test manuel avec
`dns-sd -B _zendure._tcp` ; en Swift, `NWBrowser` couvre nativement ce besoin.

Serveur HTTP embarqué sur chaque appareil :

```http
GET  http://<ip>/properties/report
POST http://<ip>/properties/write   {"sn":"…","properties":{"acMode":2}}
GET  http://<ip>/rpc?method=HA.Mqtt.GetStatus
GET  http://<ip>/rpc?method=HA.Mqtt.GetConfig
POST http://<ip>/rpc                {"sn":"…","method":"HA.Mqtt.SetConfig","params":{"config":{…}}}
```

Modèles compatibles : SolarFlow 800, 800 Plus, 800 Pro, 1600 AC+, 2400 AC, 2400 AC+, 2400 Pro,
SmartMeter3CT.

Contraintes liées à la norme EN 18031 : l'API locale s'active en **ajoutant un HEMS puis en
quittant l'app** ; le client MQTT configurable est **non-TLS uniquement** (ni port 8883 ni
`mqtts://`) ; les réponses de l'API locale sont plafonnées à **512 octets**.

### Sources

- <https://github.com/Zendure/zenSDK>
- <https://github.com/Zendure/zenSDK/blob/main/docs/fr.md> (documentation française)

---

## Propriétés et conversions

Référence la plus complète :
<https://github.com/Zendure/zenSDK/blob/main/docs/en_properties.md>, complétée par les tableaux
SuperBase V / SolarFlow du README de `developer-device-data-report`.

### Champs de mesure principaux (SolarFlow, Hyper, AIO)

| Champ | Signification |
|---|---|
| `electricLevel` | SOC moyen (%) |
| `solarInputPower`, `solarPower1`…`solarPower6` | production PV totale et par voie (W) |
| `packInputPower` | puissance de décharge batterie (W) |
| `outputPackPower` | puissance de charge batterie (W) |
| `outputHomePower` | puissance envoyée vers la maison (W) |
| `gridInputPower` | puissance prise au réseau (W) |
| `remainOutTime`, `remainInputTime` | autonomie / temps de charge restants (minutes) |
| `packNum` | nombre de packs batterie |
| `packState` | 0 veille, 1 charge, 2 décharge |
| `hyperTmp` | température de l'enceinte |
| `rssi` | niveau de signal (dBm) |
| `acStatus`, `dcStatus`, `pvStatus`, `gridState` | états des étages de conversion |

### Champs inscriptibles

| Champ | Plage | Signification |
|---|---|---|
| `acMode` | 1-2 | 1 charge, 2 décharge |
| `inputLimit` | W | limite de charge AC |
| `outputLimit` | W | limite de sortie |
| `socSet` | 70-100 | SOC cible |
| `minSoc` | 0-50 | SOC minimal |
| `inverseMaxPower` | W | puissance max de l'onduleur |
| `gridReverse` | 0-2 | contrôle de l'injection |
| `gridStandard` | 0-9 | 0 Allemagne, **1 France**, 2 Autriche, 3 Suisse, 4 Pays-Bas, 5 Espagne, 6 Belgique, 7 Grèce, 8 Danemark, 9 Italie |
| `smartMode` | 0-1 | 1 = ne pas écrire en flash — **à utiliser pour les changements fréquents** |
| `gridOffMode` | 0-2 | 0 standard, 1 économique, 2 fermeture |

### Conversions à ne pas rater

- **Températures** (`maxTemp`, `hyperTmp`) en dixièmes de Kelvin : `°C = (valeur - 2731) / 10`.
  Un `hyperTmp: 2981` vaut 25 °C.
- **Tensions** `maxVol`, `minVol`, `BatVolt` en centièmes de volt (`× 0.01`). `totalVol` est
  documenté en volts par zenSDK mais en centièmes par le README historique — à valider sur
  données réelles.
- **`batcur`** : complément à deux 16 bits, à lire en `Int16` signé puis diviser par 10 pour
  obtenir des ampères.
- **`socSet` a deux échelles selon la source** : le README officiel montre `80` (pourcentage
  direct), le client evcc commente `1000`. Ne pas coder en dur — détecter à l'exécution
  (valeur > 100 ⇒ diviser par 10).

### `packData`

Tableau imbriqué, une entrée par pack batterie, à traiter séparément de `properties` :

```json
"packData": [{
  "sn": "…", "socLevel": 98, "state": 1, "power": 120,
  "maxVol": 334, "minVol": 332, "maxTemp": 2985,
  "totalVol": 5320, "batcur": -15, "softVersion": 0, "heatState": 0
}]
```

Le `sn` du pack sert de clé stable pour rattacher les mesures à une batterie donnée.
Les messages `properties/report` sont **partiels** et n'incluent pas toujours `packData` :
le client doit **fusionner** les rapports dans un état persistant, jamais remplacer.

---

## Historisation (recherche du 10 août 2026)

> Question : existe-t-il une API d'historique (jusqu'à 365 jours) ? Réponse courte : **oui,
> mais uniquement via l'API privée de l'app mobile** (login email/mot de passe), pas via le
> Cloud Key. Aucune API d'historique officielle n'existe.

### Ce qui est exclu

- **Méthode 1 (Cloud Key / `zenHa`)** : `api.py` de Zendure-HA ET `zenWebService.ts` de
  ioBroker.zendure-solarflow (vérifiés le 2026-08-10, repo actif) confirment que
  `/api/ha/deviceList` est le SEUL endpoint de cette famille. Pas d'historique possible avec
  cette auth. ioBroker fabrique d'ailleurs ses statistiques d'énergie **localement**
  (`calculateEnergy()` toutes les 30 s, remise à zéro à minuit via node-schedule, persistance
  dans les states ioBroker) — exactement l'approche de nos `EnergyCounters`, avec persistance
  en plus.
- **API officielle** : demandes répétées sur le forum Zendure (ex. discussion 26660, « Can we
  please get an API to retrieve the historic data… not only real-time via MQTT ») **sans
  réponse de Zendure**. Les utilisateurs se voient conseiller de logger localement.

### Les endpoints d'historique de l'app mobile (API privée, non contractuelle)

Source principale : module FHEM `RP-Develop/Zendure` (actif, dernier push 2025-04), qui les
utilise en production. Ce sont les endpoints qui alimentent les graphiques jour/semaine/mois/
année de l'app.

**1. Login** (méthode 3 du présent rapport — donc fonctionnelle en 2025, contrairement au
statut « non vérifiée » noté en août 2026) :

```http
POST https://app.zendure.tech/{région}/auth/app/token        # eu, v2 (global), as…
Authorization: Basic Q29uc3VtZXJBcHA6NX4qUmRuTnJATWg0WjEyMw==
appVersion: 4.3.1
User-Agent: Zendure/4.3.1 (iPhone; iOS 14.4.2; Scale/3.00)

{"password":"…","account":"…","appId":"121c83f761305d6cf7e",
 "appType":"iOS","grantType":"password","tenantId":""}
```

La réponse fournit `data.accessToken` (→ en-tête `Blade-Auth: bearer <token>`), et surtout
**`data.serverNodeUrl`** — le nœud régional de données qui héberge les endpoints tdengine —
plus `iotUrl`/`iotUserName` (MQTT compte entier) et `zone`.

**2. Historique** (TDengine = base de séries temporelles côté Zendure) :

```http
POST {serverNodeUrl}/tdengine/device/solarFlow/energy      # énergies agrégées (kWh)
POST {serverNodeUrl}/tdengine/device/solarFlow/electric    # courbes de puissance
Blade-Auth: bearer <accessToken>

{"aceId":"", "deviceId":"<deviceId>", "beginDate":"2026-08-10",
 "endDate":"2026-08-10", "zone":"Europe/Paris", "type":0}
```

- `type: 0` + `beginDate = endDate = jour` → données du jour.
- `type: ""` + dates vides → totaux sur toute la vie de l'appareil.
- Les autres valeurs de `type` (vraisemblablement semaine/mois/année, vu les onglets de
  l'app) **restent à découvrir par sondage réel** — FHEM n'utilise que 0 et "".
- Champs de réponse observés : `solar`, `home`, `batteryInput`, `batteryOutput`,
  `gridInputTotal`, `acOutputTotal`, `dcOutputTotal`, `socketOutputTotal`, `gridDirectTotal`,
  `outputToInverse`, `outputToBindDevice`, `bindDeviceInput` (sous-ensembles selon
  productType : Hub 2000 = 4 champs, Hyper 2000 = 5).
- La réponse contient aussi **`energyVos` et `data`** : les séries temporelles des graphiques
  (FHEM les supprime avant stockage — `#Diagrammdaten gelöscht` — mais elles sont bien
  renvoyées). C'est là que se trouve la granularité fine.

**3. Annexes** : `{serverNodeUrl}/device/solarFlow/detail` (`{"deviceId":…}`) et
`https://app.zendure.tech/{région}/platform/h5/time`.

### Sur les 365 jours

L'app affiche une vue « année », donc la rétention côté Zendure est d'au moins un an. Deux
stratégies : itérer 365 appels `type:0` jour par jour (lourd mais sûr), ou identifier la
valeur de `type` « année » qui renvoie 12 points mensuels (à sonder). La profondeur réelle de
rétention (> 1 an ?) n'est documentée nulle part.

### Implémentation éventuelle dans ZendureCloud

1. Second mode d'auth **optionnel** (email/mot de passe → Keychain), service isolé du chemin
   Cloud Key — l'API app est encore moins contractuelle que le reste.
2. Sonder `type` 0/1/2/3/4 sur un jour/mois/an pour cartographier les granularités et le
   contenu d'`energyVos` (la console MQTT ne sert à rien ici : c'est du HTTP).
3. Vue « Historique » (Swift Charts) : barres kWh/jour + totaux vie entière ; en repli, la
   persistance locale des `EnergyCounters` (déjà au backlog) reste la solution sans cloud.

### Sources

- <https://github.com/RP-Develop/Zendure/blob/main/FHEM/ZendureUtils.pm> (requêtes complètes)
- <https://github.com/Zendure/Zendure-HA/blob/master/custom_components/zendure_ha/api.py>
- <https://github.com/bmachuletz/ZendureShell> (login PowerShell, mêmes endpoints)
- <https://flarum-eu.zendure.tech/d/26660> (absence d'API officielle d'historique)

---

## Recommandations d'implémentation pour le client Swift

1. Écran de configuration demandant le **Cloud Key** (méthode 1), pas email/mot de passe.
2. Décodage base64, appel signé de `/api/ha/deviceList`, stockage du jeton dans le **Keychain**.
3. Connexion MQTT avec les identifiants renvoyés, abonnement aux **deux** formes de topic par
   appareil.
4. État fusionné en mémoire alimenté par `properties/report`, plus un `properties/read` +
   `getAll` toutes les 60 secondes comme filet de sécurité.
5. Prévoir la méthode 4 (zenSDK local) comme second transport pour les modèles récents : le
   modèle de propriétés est identique, donc le décodage JSON est mutualisable.

**Mises en garde.** Ce sont des API non publiques et non contractuelles : les deux intégrations
majeures ont dû migrer d'authentification en 2025-2026, donc la couche d'authentification doit
rester isolée et remplaçable. Et rien de ce document n'a été validé contre un serveur réel.

import Foundation

/// Documentation des propriétés publiées par le Cloud Zendure, affichée dans
/// la carte « Toutes les propriétés ».
///
/// Sources : zenSDK (docs/en_properties.md), intégration Home Assistant
/// officielle Zendure-HA, ioBroker.zendure-solarflow, README de
/// developer-device-data-report, et le vocabulaire relevé dans ZendureMonitor.
/// Voir ZENDURE_API_RESEARCH.md à la racine du projet.
enum PropertyCatalog {
    struct Doc {
        let description: String
        /// Unité ou encodage brut, si piégeux (ex. « dixièmes de kelvin »).
        let unit: String?
    }

    /// Documentation d'une clé, gérant les clés indexées (`solarPower3`) et
    /// les entrées de packs (`packData[SN]`).
    static func doc(for key: String) -> Doc? {
        if let doc = catalog[key] { return doc }
        if key.hasPrefix("solarPower"), let channel = Int(key.dropFirst("solarPower".count)) {
            return Doc(description: "Puissance produite par l'entrée MPPT n°\(channel).", unit: "W")
        }
        if key.hasPrefix("packData[") {
            return Doc(description: "Rapport complet d'un pack batterie (identifié par son numéro de série) : SOC, tension, température, courant, version logicielle.", unit: nil)
        }
        return nil
    }

    private static let catalog: [String: Doc] = [
        // MARK: État de charge et batterie
        "electricLevel": Doc(description: "État de charge global du système (moyenne des packs).", unit: "%"),
        "socLevel": Doc(description: "État de charge (variante de electricLevel selon firmware).", unit: "%"),
        "socSet": Doc(description: "Limite haute de charge configurée (plage 70–100 %).", unit: "% (parfois en dixièmes : 800 = 80 %)"),
        "minSoc": Doc(description: "Limite basse de décharge configurée (plage 0–50 %).", unit: "% (parfois en dixièmes)"),
        "packNum": Doc(description: "Nombre de packs batterie raccordés.", unit: nil),
        "packState": Doc(description: "État global des batteries : 0 = veille, 1 = charge, 2 = décharge.", unit: nil),
        "BatVolt": Doc(description: "Tension du bus batterie.", unit: "centièmes de volt (5230 = 52,30 V)"),
        "batcur": Doc(description: "Courant batterie, signé (négatif = décharge selon firmware).", unit: "dixièmes d'ampère, Int16 signé"),
        "remainOutTime": Doc(description: "Autonomie restante estimée en décharge. 59940 = non disponible.", unit: "min"),
        "remainInputTime": Doc(description: "Temps restant estimé jusqu'à pleine charge. 59940 = non disponible.", unit: "min"),
        "heatState": Doc(description: "Chauffage des batteries actif (protection basse température).", unit: "0/1"),

        // MARK: Puissances instantanées
        "solarInputPower": Doc(description: "Puissance solaire totale entrante (somme des MPPT).", unit: "W"),
        "outputHomePower": Doc(description: "Puissance injectée vers la maison (via micro-onduleur ou prise AC).", unit: "W"),
        "gridInputPower": Doc(description: "Puissance tirée du réseau (charge secteur).", unit: "W"),
        "packInputPower": Doc(description: "Puissance sortant des batteries (décharge).", unit: "W"),
        "outputPackPower": Doc(description: "Puissance entrant dans les batteries (charge).", unit: "W"),
        "gridOffPower": Doc(description: "Puissance délivrée sur la prise hors réseau (backup).", unit: "W"),
        "offGridPower": Doc(description: "Puissance délivrée sur la prise hors réseau (backup).", unit: "W"),

        // MARK: Configuration et limites
        "acMode": Doc(description: "Mode AC : 1 = charge depuis le secteur, 2 = injection vers la maison.", unit: nil),
        "inputLimit": Doc(description: "Plafond de puissance d'entrée (charge secteur).", unit: "W"),
        "outputLimit": Doc(description: "Plafond de puissance de sortie (injection).", unit: "W"),
        "inverseMaxPower": Doc(description: "Puissance maximale acceptée par le micro-onduleur configuré.", unit: "W"),
        "gridReverse": Doc(description: "Comportement anti-injection réseau (selon configuration HEMS).", unit: nil),
        "gridStandard": Doc(description: "Norme réseau du pays : 0 Allemagne, 1 France, 2 Autriche, 3 Suisse, 4 Pays-Bas, 5 Espagne, 6 Belgique, 7 Grèce, 8 Danemark, 9 Italie.", unit: nil),
        "smartMode": Doc(description: "1 = les écritures de réglages ne sont pas persistées en flash (préserve la mémoire pour les changements fréquents).", unit: nil),
        "autoModel": Doc(description: "Mode de pilotage automatique (0 = manuel ; autres valeurs selon mode IA/HEMS/CT).", unit: nil),
        "passMode": Doc(description: "Mode bypass : routage direct du solaire ou du secteur vers la sortie sans passer par la batterie.", unit: nil),
        "autoRecover": Doc(description: "Retour automatique au mode normal après un bypass programmé.", unit: "0/1"),
        "masterSwitch": Doc(description: "Interrupteur général de l'appareil.", unit: "0/1"),
        "buzzerSwitch": Doc(description: "Signal sonore activé.", unit: "0/1"),
        "lampSwitch": Doc(description: "Éclairage/LED de l'appareil activé.", unit: "0/1"),

        // MARK: États et statuts
        "acStatus": Doc(description: "Statut du convertisseur AC.", unit: "bitmask"),
        "dcStatus": Doc(description: "Statut du convertisseur DC.", unit: "bitmask"),
        "pvStatus": Doc(description: "Statut des entrées photovoltaïques.", unit: "bitmask"),
        "gridState": Doc(description: "Présence/état du réseau électrique.", unit: nil),
        "hubState": Doc(description: "Comportement en coupure réseau : 0 = continuer l'injection, 1 = basculer sur la prise de secours.", unit: nil),
        "wifiState": Doc(description: "État de la connexion Wi-Fi.", unit: "0/1"),
        "wifiStatus": Doc(description: "État de la connexion Wi-Fi (variante).", unit: "0/1"),
        "rssi": Doc(description: "Puissance du signal Wi-Fi (plus proche de 0 = meilleur).", unit: "dBm"),
        "ssid": Doc(description: "Nom du réseau Wi-Fi auquel l'appareil est connecté.", unit: nil),
        "hyperTmp": Doc(description: "Température interne de l'appareil.", unit: "dixièmes de kelvin (2981 = 25,0 °C)"),

        // MARK: Identité et versions
        "product": Doc(description: "Identifiant du modèle produit (ex. solarFlow2400Pro).", unit: nil),
        "sn": Doc(description: "Numéro de série de l'appareil.", unit: nil),
        "deviceId": Doc(description: "Identifiant de l'appareil dans le cloud (deviceKey).", unit: nil),
        "softVersion": Doc(description: "Version du firmware principal.", unit: "encodée"),
        "masterSoftVersion": Doc(description: "Version du firmware du module maître.", unit: "encodée"),
        "masterhaerVersion": Doc(description: "Version matérielle du module maître.", unit: "encodée"),
        "version": Doc(description: "Version du protocole/firmware du message.", unit: nil),
        "blueOta": Doc(description: "Capacité de mise à jour OTA via Bluetooth.", unit: nil),
        "pvBrand": Doc(description: "Marque du micro-onduleur configurée dans l'app.", unit: "code"),

        // MARK: Message
        "timestamp": Doc(description: "Horodatage d'émission du rapport par l'appareil.", unit: "epoch s"),
        "messageId": Doc(description: "Identifiant du message MQTT (compteur).", unit: nil),

        // MARK: Champs de packs (visibles dans packData)
        "maxTemp": Doc(description: "Température maximale relevée dans le pack.", unit: "dixièmes de kelvin"),
        "maxVol": Doc(description: "Tension de la cellule la plus haute.", unit: "centièmes de volt"),
        "minVol": Doc(description: "Tension de la cellule la plus basse.", unit: "centièmes de volt"),
        "totalVol": Doc(description: "Tension totale du pack.", unit: "V ou centièmes selon firmware"),
        "power": Doc(description: "Puissance instantanée du pack (signe selon charge/décharge).", unit: "W"),
        "state": Doc(description: "État du pack : 0 = veille, 1 = charge, 2 = décharge.", unit: nil),
    ]
}

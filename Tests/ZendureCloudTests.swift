import XCTest
@testable import ZendureCloud

final class CloudKeyTests: XCTestCase {
    func testDecodeValidToken() throws {
        // "https://app.zendure.tech/eu.myAppKey123" en base64
        let token = Data("https://app.zendure.tech/eu.myAppKey123".utf8).base64EncodedString()
        let key = try CloudKey.decode(token)
        XCTAssertEqual(key.apiUrl.absoluteString, "https://app.zendure.tech/eu")
        XCTAssertEqual(key.appKey, "myAppKey123")
    }

    func testDecodeSplitsOnLastDot() throws {
        let token = Data("https://api.zendure.example.com.abc123".utf8).base64EncodedString()
        let key = try CloudKey.decode(token)
        XCTAssertEqual(key.apiUrl.absoluteString, "https://api.zendure.example.com")
        XCTAssertEqual(key.appKey, "abc123")
    }

    func testDecodeTokenWithoutPadding() throws {
        var token = Data("https://a.io.key".utf8).base64EncodedString()
        token = token.replacingOccurrences(of: "=", with: "")
        let key = try CloudKey.decode(token)
        XCTAssertEqual(key.appKey, "key")
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try CloudKey.decode("%%%non-base64%%%"))
        XCTAssertThrowsError(try CloudKey.decode(Data("pas-de-point-du-tout".utf8).base64EncodedString()))
    }
}

final class SignatureTests: XCTestCase {
    func testSignSortsKeysAndUppercases() {
        // Vecteur calculé indépendamment : SHA1("C*dafwArEOXK" + "appKeyAnonce12345timestamp1700000000" + "C*dafwArEOXK")
        let sign = ZendureAPI.sign(parameters: [
            "timestamp": "1700000000",
            "appKey": "A",
            "nonce": "12345",
        ])
        XCTAssertEqual(sign.count, 40)
        XCTAssertEqual(sign, sign.uppercased())
        // La même entrée doit toujours produire la même signature (déterminisme).
        let again = ZendureAPI.sign(parameters: ["appKey": "A", "nonce": "12345", "timestamp": "1700000000"])
        XCTAssertEqual(sign, again)
    }

    func testDeviceListRequestHeaders() throws {
        let key = CloudKey(apiUrl: URL(string: "https://app.zendure.tech/eu")!, appKey: "abc")
        let request = ZendureAPI.deviceListRequest(cloudKey: key, now: Date(timeIntervalSince1970: 1_700_000_000), nonce: 54321)
        XCTAssertEqual(request.url?.absoluteString, "https://app.zendure.tech/eu/api/ha/deviceList")
        XCTAssertEqual(request.value(forHTTPHeaderField: "clientid"), "zenHa")
        XCTAssertEqual(request.value(forHTTPHeaderField: "timestamp"), "1700000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "nonce"), "54321")
        XCTAssertEqual(request.value(forHTTPHeaderField: "sign")?.count, 40)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["appKey": "abc"])
    }
}

final class MQTTPacketTests: XCTestCase {
    func testRemainingLengthRoundTrip() {
        for length in [0, 1, 127, 128, 16383, 16384, 2_097_151] {
            var data = Data([0x30])
            data.append(MQTTPacket.encodeRemainingLength(length))
            let decoded = MQTTPacket.decodeRemainingLength(data)
            XCTAssertEqual(decoded?.length, length, "longueur \(length)")
        }
    }

    func testConnectPacketShape() {
        let packet = MQTTPacket.connect(clientId: "cid", username: "user", password: "pass", keepAlive: 60)
        XCTAssertEqual(packet[0], 0x10)
        // Protocole "MQTT" niveau 4, flags 0xC2
        XCTAssertTrue(packet.contains(0x04))
        // Le paquet doit contenir clientId, username, password en clair UTF-8.
        let raw = String(decoding: packet, as: UTF8.self)
        XCTAssertTrue(raw.contains("cid"))
        XCTAssertTrue(raw.contains("user"))
        XCTAssertTrue(raw.contains("pass"))
    }

    func testParsePublishQoS0() {
        var buffer = MQTTPacket.publish(topic: "iot/pk/dk/properties/report", payload: Data("{\"a\":1}".utf8))
        let incoming = MQTTPacket.parse(from: &buffer)
        guard case .publish(let topic, let payload, let packetId) = incoming else {
            return XCTFail("attendu un PUBLISH, reçu \(String(describing: incoming))")
        }
        XCTAssertEqual(topic, "iot/pk/dk/properties/report")
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "{\"a\":1}")
        XCTAssertNil(packetId)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testParsePublishQoS1CarriesPacketId() {
        // PUBLISH QoS1 construit à la main : header 0x32, topic "t", packetId 7, payload "x"
        var body = MQTTPacket.encodeString("t")
        body.append(contentsOf: [0x00, 0x07])
        body.append(Data("x".utf8))
        var buffer = Data([0x32])
        buffer.append(MQTTPacket.encodeRemainingLength(body.count))
        buffer.append(body)
        let incoming = MQTTPacket.parse(from: &buffer)
        guard case .publish(_, _, let packetId) = incoming else {
            return XCTFail("attendu un PUBLISH")
        }
        XCTAssertEqual(packetId, 7)
    }

    func testParseIncompleteBufferReturnsNilAndKeepsBytes() {
        let full = MQTTPacket.publish(topic: "topic", payload: Data(repeating: 0x41, count: 50))
        let cut = full.count - 10
        var partial = Data(full.prefix(cut))
        XCTAssertNil(MQTTPacket.parse(from: &partial))
        XCTAssertEqual(partial.count, cut)  // rien consommé
        // Une fois complété, le paquet se parse.
        partial.append(full.suffix(10))
        XCTAssertNotNil(MQTTPacket.parse(from: &partial))
    }

    func testParseConnack() {
        var buffer = Data([0x20, 0x02, 0x00, 0x00])
        XCTAssertEqual(MQTTPacket.parse(from: &buffer), .connack(returnCode: 0))
    }

    func testParseTwoPacketsInOneBuffer() {
        var buffer = Data([0x20, 0x02, 0x00, 0x00, 0xD0, 0x00])
        XCTAssertEqual(MQTTPacket.parse(from: &buffer), .connack(returnCode: 0))
        XCTAssertEqual(MQTTPacket.parse(from: &buffer), .pingresp)
        XCTAssertNil(MQTTPacket.parse(from: &buffer))
    }
}

final class DeviceStateTests: XCTestCase {
    func testMergeFlatAndNestedPayloads() {
        var state = DeviceState()
        state.merge(payload: ["properties": ["electricLevel": 82, "solarInputPower": 340]])
        XCTAssertEqual(state.electricLevel, 82)
        state.merge(payload: ["outputHomePower": "215"])  // à plat + nombre en chaîne
        XCTAssertEqual(state.outputHomePower, 215)
        // La fusion garde les champs précédents.
        XCTAssertEqual(state.solarInputPower, 340)
    }

    func testUnitConversions() {
        var state = DeviceState()
        state.merge(payload: [
            "hyperTmp": 2981,          // 25,0 °C
            "BatVolt": 5230,           // 52,30 V
            "socSet": 800,             // échelle dixièmes → 80 %
            "minSoc": 20,              // échelle directe → 20 %
            "remainOutTime": 59940,    // sentinelle "indisponible"
        ])
        XCTAssertEqual(state.deviceTemperature!, 25.0, accuracy: 0.01)
        XCTAssertEqual(state.batteryVoltage!, 52.30, accuracy: 0.001)
        XCTAssertEqual(state.socMax, 80)
        XCTAssertEqual(state.socMin, 20)
        XCTAssertNil(state.remainOutMinutes)
    }

    func testPackDataMergeBySn() {
        var state = DeviceState()
        state.merge(payload: [
            "packData": [
                ["sn": "P1", "socLevel": 90, "maxTemp": 2985, "maxVol": 334, "batcur": 65521],
            ],
        ])
        XCTAssertEqual(state.packs.count, 1)
        let pack = state.packs[0]
        XCTAssertEqual(pack.socLevel, 90)
        XCTAssertEqual(pack.maxTemp!, 25.4, accuracy: 0.01)
        XCTAssertEqual(pack.maxVol!, 3.34, accuracy: 0.001)
        XCTAssertEqual(pack.current!, -1.5, accuracy: 0.001)  // 65521 → -15 → -1,5 A

        // Second rapport partiel : fusion, pas remplacement.
        state.merge(payload: ["packData": [["sn": "P1", "power": 120]]])
        XCTAssertEqual(state.packs.count, 1)
        XCTAssertEqual(state.packs[0].power, 120)
        XCTAssertEqual(state.packs[0].socLevel, 90)
    }

    func testSolarChannels() {
        var state = DeviceState()
        state.merge(payload: ["solarPower1": 120, "solarPower2": 95])
        XCTAssertEqual(state.solarChannels, [120, 95])
    }

    func testRawPropertiesCaptureEverything() {
        var state = DeviceState()
        state.merge(payload: ["properties": ["electricLevel": 82, "uneCleInconnue": 42]])
        XCTAssertNotNil(state.rawProperties["uneCleInconnue"])
        XCTAssertEqual(state.rawProperties["uneCleInconnue"]?.value, "42")
    }
}

final class BatteryCatalogTests: XCTestCase {
    func testSerialPrefixMapping() {
        // Le discriminant secondaire est le 4e caractère (index 3) du SN.
        XCTAssertEqual(BatteryCatalog.battery(forSerial: "AAAXBB")?.model, "AB1000")
        XCTAssertEqual(BatteryCatalog.battery(forSerial: "AAA3BB")?.model, "AIO 2400")
        XCTAssertEqual(BatteryCatalog.battery(forSerial: "B12345")?.model, "AB1000S")
        XCTAssertEqual(BatteryCatalog.battery(forSerial: "CCCXBB")?.model, "AB2000")
        XCTAssertEqual(BatteryCatalog.battery(forSerial: "CCCFBB")?.model, "AB2000S")
        XCTAssertEqual(BatteryCatalog.battery(forSerial: "CCCEBB")?.model, "AB2000X")
        XCTAssertEqual(BatteryCatalog.battery(forSerial: "F12345")?.kwh, 2.88)
        XCTAssertNil(BatteryCatalog.battery(forSerial: "Z12345"))
        XCTAssertNil(BatteryCatalog.battery(forSerial: ""))
    }

    func testDeviceCapacityAndAvailable() {
        var state = DeviceState()
        state.merge(payload: [
            "electricLevel": 60,
            "minSoc": 10,
            "packData": [["sn": "CO4AAA"], ["sn": "CO4BBB"]],  // 2 × AB2000 = 3,84 kWh
        ])
        XCTAssertEqual(state.totalCapacityKwh!, 3.84, accuracy: 0.001)
        // (60 − 10) % de 3,84 kWh = 1,92 kWh
        XCTAssertEqual(state.availableKwh!, 1.92, accuracy: 0.001)
    }

    func testEstimatedRemainMinutes() {
        var state = DeviceState()
        state.merge(payload: [
            "electricLevel": 60,
            "minSoc": 10,
            "packInputPower": 960,  // décharge nette 960 W
            "packData": [["sn": "CO4AAA"], ["sn": "CO4BBB"]],
        ])
        // 1,92 kWh / 960 W = 2 h = 120 min
        XCTAssertEqual(state.estimatedRemainMinutes, 120)
        // Pas d'estimation en charge ou à l'arrêt.
        state.merge(payload: ["packInputPower": 0])
        XCTAssertNil(state.estimatedRemainMinutes)
    }

    func testPackDeltaVoltage() {
        var state = DeviceState()
        state.merge(payload: ["packData": [["sn": "P1", "maxVol": 334, "minVol": 331]]])
        XCTAssertEqual(state.packs[0].deltaVoltage!, 0.03, accuracy: 0.001)
    }
}

final class EnergyCountersTests: XCTestCase {
    func testIntegrationBetweenReports() {
        var state = DeviceState()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        state.merge(payload: ["solarInputPower": 600, "outputPackPower": 300], at: t0)
        XCTAssertFalse(state.energy.hasData)  // premier rapport : rien à intégrer

        // 6 minutes plus tard : 600 W × 0,1 h = 60 Wh solaire, 30 Wh charge.
        state.merge(payload: ["solarInputPower": 400], at: t0.addingTimeInterval(360))
        XCTAssertEqual(state.energy.solarWh, 60, accuracy: 0.001)
        XCTAssertEqual(state.energy.chargeWh, 30, accuracy: 0.001)
    }

    func testLongGapsAreNotIntegrated() {
        var state = DeviceState()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        state.merge(payload: ["solarInputPower": 600], at: t0)
        state.merge(payload: ["solarInputPower": 600], at: t0.addingTimeInterval(3600))
        XCTAssertEqual(state.energy.solarWh, 0)
    }

    func testRoundtripEfficiencyNeedsMinimumEnergy() {
        var counters = EnergyCounters()
        counters.accumulate(solar: nil, home: nil, grid: nil, charge: 40, discharge: 36, seconds: 3600)
        XCTAssertNil(counters.roundtripEfficiency)  // < 50 Wh de charge
        counters.accumulate(solar: nil, home: nil, grid: nil, charge: 60, discharge: 54, seconds: 3600)
        XCTAssertEqual(counters.roundtripEfficiency!, 90, accuracy: 0.001)
    }
}

final class MQTTCredentialsTests: XCTestCase {
    private func creds(_ url: String) -> MQTTCredentials {
        MQTTCredentials(clientId: "c", url: url, username: "u", password: "p")
    }

    func testHostPortSplit() {
        XCTAssertEqual(creds("mqtt.zen-iot.com:1883").host, "mqtt.zen-iot.com")
        XCTAssertEqual(creds("mqtt.zen-iot.com:1883").port, 1883)
        XCTAssertEqual(creds("mqtt.zen-iot.com").host, "mqtt.zen-iot.com")
        XCTAssertEqual(creds("mqtt.zen-iot.com").port, 1883)
        XCTAssertEqual(creds("broker:8883").port, 8883)
    }
}

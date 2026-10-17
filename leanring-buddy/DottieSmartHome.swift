//
//  DottieSmartHome.swift
//  leanring-buddy
//
//  One controller for everything smart in the house, by voice and in
//  Home → Smart Home:
//
//  - TVs (DottieTV): Android TV, Google TV and Fire TV over ADB, Rokus, and
//    any TV through an HDMI capture card plus a USB keyboard adapter. Dottie
//    can see a TV's screen and do multi-step jobs on it (DottieTVTaskRunner),
//    or mirror it into a window on the Mac.
//  - Philips Hue lights and rooms, through the bridge's local API.
//  - Home Assistant: every light, switch, plug, fan, blind, lock, vacuum,
//    thermostat, speaker, scene and camera it knows, which covers most
//    brands (and HomeKit or Matter devices it's bridged to).
//  - Apple Home has no API for Mac apps, so Dottie uses the user's
//    Shortcuts for it, or works the Home app on screen.
//
//  TVs, the Hue bridge and the Home Assistant address are saved in
//  Application Support/Dottie/home.json; the Hue key and the Home Assistant
//  token in home-secrets.json, readable only by the user.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import ImageIO
import Network

@MainActor
final class DottieSmartHome: ObservableObject {
    // MARK: - Saved setup

    struct TV: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case android     // Android TV, Google TV, Fire TV (ADB)
            case roku
            case anyTV       // capture card + USB keyboard adapter
        }
        var id = UUID()
        var name: String
        var kind: Kind
        /// ADB serial (ip:port) or the Roku's IP address.
        var address: String
        /// A capture card that shows this TV's picture (its eyes, for a
        /// Roku or any other TV).
        var captureDeviceID: String?
        /// A CH9329 keyboard adapter's serial port (its hands, any TV).
        var keyboardPort: String?
    }

    struct Setup: Codable {
        var tvs: [TV] = []
        var hueBridgeAddress: String?
        var homeAssistantURL: String?
    }

    private struct Secrets: Codable {
        var hueUsername: String?
        var homeAssistantToken: String?
    }

    @Published private(set) var setup = Setup()
    private var secrets = Secrets()

    // MARK: - Live state

    struct FoundDevice: Identifiable, Equatable {
        enum Kind: String { case androidTV, roku, hueBridge, homeAssistant }
        var id: String { "\(kind.rawValue)-\(host)" }
        let name: String
        let host: String
        let kind: Kind
        /// For Home Assistant: its address from the network.
        var url: String?
    }

    struct Light: Identifiable, Equatable {
        let id: String
        let name: String
        let isRoom: Bool
        var isOn: Bool
        var brightnessPercent: Int?
    }

    struct HomeAssistantEntity: Identifiable, Equatable {
        var id: String { entityID }
        let entityID: String
        let name: String
        let state: String
        var domain: String { String(entityID.split(separator: ".").first ?? "") }
    }

    @Published private(set) var foundDevices: [FoundDevice] = []
    @Published private(set) var isSearching = false
    @Published private(set) var tvStatus: [UUID: String] = [:]
    @Published private(set) var lights: [Light] = []
    @Published private(set) var homeAssistantEntities: [HomeAssistantEntity] = []
    @Published var statusMessage: String?
    @Published private(set) var isInstallingTVTools = false

    var isHueConnected: Bool { setup.hueBridgeAddress != nil && secrets.hueUsername != nil }
    var isHomeAssistantConnected: Bool { setup.homeAssistantURL != nil && secrets.homeAssistantToken != nil }

    let tvTaskRunner = DottieTVTaskRunner()

    private let folderURL: URL
    private var setupURL: URL { folderURL.appendingPathComponent("home.json") }
    private var secretsURL: URL { folderURL.appendingPathComponent("home-secrets.json") }
    private var browsers: [NWBrowser] = []

    /// Home Assistant domains worth listing and controlling.
    private static let usefulDomains: Set<String> = [
        "light", "switch", "fan", "cover", "lock", "climate", "media_player", "vacuum", "scene", "script",
        "camera", "humidifier", "input_boolean", "water_heater", "alarm_control_panel"
    ]

    init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = applicationSupportURL.appendingPathComponent("Dottie", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: setupURL), let savedSetup = try? JSONDecoder().decode(Setup.self, from: data) {
            setup = savedSetup
        }
        if let data = try? Data(contentsOf: secretsURL), let savedSecrets = try? JSONDecoder().decode(Secrets.self, from: data) {
            secrets = savedSecrets
        }
    }

    /// Refreshes what everything is doing (Home tab, and before listing).
    func refresh() async {
        for tv in setup.tvs {
            tvStatus[tv.id] = await status(of: tv)
        }
        if isHueConnected { await refreshHueLights() }
        if isHomeAssistantConnected { await refreshHomeAssistant() }
    }

    // MARK: - Finding things on the network

    func searchNetwork() {
        guard !isSearching else { return }
        isSearching = true
        foundDevices = []
        browsers.forEach { $0.cancel() }
        browsers = []
        let services: [(String, FoundDevice.Kind)] = [
            ("_androidtvremote2._tcp", .androidTV),
            ("_googlecast._tcp", .androidTV),
            ("_adb-tls-connect._tcp", .androidTV),
            ("_hue._tcp", .hueBridge),
            ("_home-assistant._tcp", .homeAssistant)
        ]
        for (serviceType, kind) in services {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    for result in results { await self?.noteBrowseResult(result, kind: kind, serviceType: serviceType) }
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
        Task {
            for rokuHost in await DottieTV.discoverRokus() {
                let rokuName = await DottieTV.rokuName(host: rokuHost) ?? "Roku"
                addFound(FoundDevice(name: rokuName, host: rokuHost, kind: .roku))
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            browsers.forEach { $0.cancel() }
            browsers = []
            isSearching = false
            if foundDevices.isEmpty {
                statusMessage = "Didn't find anything. Make sure the TV is on and on the same Wi-Fi, or type its address."
            }
        }
    }

    private func noteBrowseResult(_ result: NWBrowser.Result, kind: FoundDevice.Kind, serviceType: String) async {
        guard case .service(let serviceName, _, _, _) = result.endpoint else { return }
        var txtValues: [String: String] = [:]
        if case .bonjour(let txtRecord) = result.metadata {
            txtValues = txtRecord.dictionary
        }
        // Chromecasts that aren't TVs (speakers, dongles) still show up;
        // only keep the ones that look like TVs.
        if serviceType == "_googlecast._tcp" {
            let model = (txtValues["md"] ?? "").lowercased()
            guard model.contains("tv") || model.contains("shield") || model.contains("bravia") else { return }
        }
        guard let (host, port) = await Self.resolveAddress(of: result.endpoint) else { return }
        let friendlyName = txtValues["fn"] ?? serviceName
        // Wireless debugging listens on its own port; the rest use defaults.
        var found = FoundDevice(name: friendlyName, host: serviceType == "_adb-tls-connect._tcp" ? "\(host):\(port)" : host, kind: kind)
        if kind == .homeAssistant {
            found.url = txtValues["internal_url"] ?? txtValues["base_url"] ?? "http://\(host):8123"
        }
        addFound(found)
    }

    private func addFound(_ device: FoundDevice) {
        let isSaved = setup.tvs.contains { $0.address.hasPrefix(device.host) }
            || (device.kind == .hueBridge && setup.hueBridgeAddress == device.host)
        guard !isSaved, !foundDevices.contains(where: { $0.host == device.host && $0.kind == device.kind }) else { return }
        foundDevices.append(device)
    }

    /// A Bonjour service's IPv4 address and port.
    private static func resolveAddress(of endpoint: NWEndpoint) async -> (String, UInt16)? {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            var didResume = false
            func finish(_ address: (String, UInt16)?) {
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                continuation.resume(returning: address)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let remoteEndpoint = connection.currentPath?.remoteEndpoint, case .hostPort(let host, let port) = remoteEndpoint {
                        var hostText = "\(host)"
                        if let percentIndex = hostText.firstIndex(of: "%") { hostText = String(hostText[..<percentIndex]) }
                        finish((hostText, port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }

    // MARK: - TVs

    func installTVTools() async {
        isInstallingTVTools = true
        statusMessage = "Installing adb and scrcpy with Homebrew…"
        let failure = await DottieTV.installTVTools()
        isInstallingTVTools = false
        statusMessage = failure.map { "Couldn't install: \($0)" } ?? "TV tools installed."
        objectWillChange.send()
    }

    /// Adds an Android TV after connecting to it. Returns nil when added.
    func addAndroidTV(name: String, address: String) async -> String? {
        guard DottieTV.isADBInstalled else { return "Install the TV tools first (adb)." }
        let fullAddress = address.contains(":") ? address : "\(address):5555"
        if let problem = await DottieTV.adbConnect(address: fullAddress) { return problem }
        upsertTV(TV(name: name.isEmpty ? "TV" : name, kind: .android, address: fullAddress))
        return nil
    }

    func pairAndroidTV(pairingAddress: String, code: String) async -> String? {
        guard DottieTV.isADBInstalled else { return "Install the TV tools first (adb)." }
        return await DottieTV.adbPair(address: pairingAddress, code: code)
    }

    func addRoku(name: String, host: String) async -> String? {
        guard await DottieTV.rokuName(host: host) != nil else {
            return "No Roku answered at \(host). Check the address, and set Control by mobile apps to Permissive in its settings."
        }
        upsertTV(TV(name: name.isEmpty ? "Roku" : name, kind: .roku, address: host))
        return nil
    }

    func addAnyTV(name: String, captureDeviceID: String?, keyboardPort: String?) {
        upsertTV(TV(name: name.isEmpty ? "TV" : name, kind: .anyTV, address: "", captureDeviceID: captureDeviceID, keyboardPort: keyboardPort))
    }

    func updateTV(_ tv: TV) {
        upsertTV(tv)
    }

    func removeTV(_ tv: TV) {
        DottieTV.stopMirroring(serial: tv.address)
        setup.tvs.removeAll { $0.id == tv.id }
        saveSetup()
    }

    private func upsertTV(_ tv: TV) {
        if let index = setup.tvs.firstIndex(where: { $0.id == tv.id || (!tv.address.isEmpty && $0.address == tv.address) }) {
            var updatedTV = tv
            updatedTV.id = setup.tvs[index].id
            setup.tvs[index] = updatedTV
        } else {
            setup.tvs.append(tv)
        }
        foundDevices.removeAll { !tv.address.isEmpty && tv.address.hasPrefix($0.host) }
        saveSetup()
    }

    private func status(of tv: TV) async -> String {
        switch tv.kind {
        case .android:
            if !(await DottieTV.adbIsConnected(serial: tv.address)) {
                // TVs drop the connection when they sleep; try once.
                guard await DottieTV.adbConnect(address: tv.address) == nil else { return "not connected" }
            }
            return await DottieTV.adbStatus(serial: tv.address)
        case .roku:
            return await DottieTV.rokuName(host: tv.address) == nil ? "not answering" : "connected"
        case .anyTV:
            let eyes = tv.captureDeviceID.flatMap { captureDeviceName(id: $0) }.map { "sees through \($0)" }
            let hands = tv.keyboardPort.map { _ in "keyboard adapter" }
            return [eyes, hands].compactMap { $0 }.joined(separator: ", ").nonEmpty ?? "needs a capture card or keyboard adapter"
        }
    }

    private func captureDeviceName(id: String) -> String? {
        DottieTV.captureDevices().first { $0.uniqueID == id }?.localizedName
    }

    /// Presses a remote button on a TV.
    func press(_ keyName: String, on tv: TV) async -> Bool {
        switch tv.kind {
        case .android:
            return await DottieTV.adbPress(serial: tv.address, keyName: keyName)
        case .roku:
            return await DottieTV.rokuPress(host: tv.address, keyName: keyName)
        case .anyTV:
            guard let port = tv.keyboardPort else { return false }
            return DottieTV.keyboardAdapterPress(port: port, keyName: keyName)
        }
    }

    private func type(_ text: String, on tv: TV) async -> Bool {
        switch tv.kind {
        case .android: return await DottieTV.adbType(serial: tv.address, text: text)
        case .roku: return await DottieTV.rokuType(host: tv.address, text: text)
        case .anyTV:
            guard let port = tv.keyboardPort else { return false }
            return DottieTV.keyboardAdapterType(port: port, text: text)
        }
    }

    private func openApp(_ name: String, on tv: TV) async -> String {
        switch tv.kind {
        case .android: return await DottieTV.adbOpenApp(serial: tv.address, name: name)
        case .roku: return await DottieTV.rokuOpenApp(host: tv.address, name: name)
        case .anyTV:
            // With only a keyboard: home, then the search, then the name.
            _ = await press("home", on: tv)
            return "this TV can only be reached with keys: go to the app with the arrows instead."
        }
    }

    /// The TV's screen: ADB screenshot, or a frame from its capture card.
    private func screen(of tv: TV) async -> Data? {
        if let captureDeviceID = tv.captureDeviceID, let frame = await DottieTV.captureFrame(deviceID: captureDeviceID) {
            return frame
        }
        if tv.kind == .android {
            return await DottieTV.adbScreenshot(serial: tv.address)
        }
        return nil
    }

    func mirror(_ tv: TV) -> String? {
        guard tv.kind == .android else {
            return tv.captureDeviceID == nil
                ? "only Android and Google TVs can be mirrored; add a capture card to see this one."
                : "open the capture card in QuickTime (File → New Movie Recording, pick the card) to watch this TV on the Mac."
        }
        return DottieTV.startMirroring(serial: tv.address, title: "\(tv.name) (TV)")
    }

    func tvControls(for tv: TV) -> DottieTVTaskRunner.Controls {
        var openURL: ((String) async -> Bool)?
        if tv.kind == .android {
            openURL = { url in await DottieTV.adbOpenURL(serial: tv.address, url: url) }
        }
        return DottieTVTaskRunner.Controls(
            tvName: tv.name,
            captureScreen: { [weak self] in await self?.screen(of: tv) },
            press: { [weak self] key in await self?.press(key, on: tv) ?? false },
            type: { [weak self] text in await self?.type(text, on: tv) ?? false },
            openApp: { [weak self] name in await self?.openApp(name, on: tv) ?? "not available." },
            openURL: openURL
        )
    }

    func canSee(_ tv: TV) -> Bool {
        tv.kind == .android || tv.captureDeviceID != nil
    }

    // MARK: - Philips Hue

    func connectHue(bridgeAddress: String) async -> String? {
        let body = ["devicetype": "dottie#mac"]
        guard let (json, _) = await Self.requestJSON(method: "POST", url: "http://\(bridgeAddress)/api", body: body),
              let firstEntry = (json as? [[String: Any]])?.first else {
            return "No Hue bridge answered at \(bridgeAddress)."
        }
        if let success = firstEntry["success"] as? [String: Any], let username = success["username"] as? String {
            setup.hueBridgeAddress = bridgeAddress
            secrets.hueUsername = username
            saveSetup()
            saveSecrets()
            foundDevices.removeAll { $0.kind == .hueBridge }
            await refreshHueLights()
            return nil
        }
        return "Press the round button on top of the Hue bridge, then press Connect again within 30 seconds."
    }

    func disconnectHue() {
        setup.hueBridgeAddress = nil
        secrets.hueUsername = nil
        lights = []
        saveSetup()
        saveSecrets()
    }

    func refreshHueLights() async {
        guard let baseURL = hueBaseURL else { return }
        var newLights: [Light] = []
        if let (json, _) = await Self.requestJSON(method: "GET", url: "\(baseURL)/groups"), let groups = json as? [String: [String: Any]] {
            for (groupID, group) in groups where ["Room", "Zone"].contains(group["type"] as? String ?? "") {
                let state = group["state"] as? [String: Any]
                let action = group["action"] as? [String: Any]
                newLights.append(Light(
                    id: "group-\(groupID)", name: group["name"] as? String ?? "Room \(groupID)", isRoom: true,
                    isOn: (state?["any_on"] as? Bool) ?? false,
                    brightnessPercent: (action?["bri"] as? Int).map { $0 * 100 / 254 }
                ))
            }
        }
        if let (json, _) = await Self.requestJSON(method: "GET", url: "\(baseURL)/lights"), let hueLights = json as? [String: [String: Any]] {
            for (lightID, light) in hueLights {
                let state = light["state"] as? [String: Any]
                newLights.append(Light(
                    id: "light-\(lightID)", name: light["name"] as? String ?? "Light \(lightID)", isRoom: false,
                    isOn: (state?["on"] as? Bool) ?? false,
                    brightnessPercent: (state?["bri"] as? Int).map { $0 * 100 / 254 }
                ))
            }
        }
        lights = newLights.sorted { ($0.isRoom ? 0 : 1, $0.name) < ($1.isRoom ? 0 : 1, $1.name) }
    }

    private var hueBaseURL: String? {
        guard let address = setup.hueBridgeAddress, let username = secrets.hueUsername else { return nil }
        return "http://\(address)/api/\(username)"
    }

    /// Sets a Hue light or room: on, brightness (0-100), color name.
    func setHue(_ light: Light, isOn: Bool? = nil, brightnessPercent: Int? = nil, colorName: String? = nil) async -> Bool {
        guard let baseURL = hueBaseURL else { return false }
        var state: [String: Any] = [:]
        if let isOn { state["on"] = isOn }
        if let brightnessPercent {
            state["on"] = brightnessPercent > 0
            state["bri"] = max(1, min(254, brightnessPercent * 254 / 100))
        }
        if let colorName {
            state["on"] = true
            state.merge(Self.hueColor(named: colorName)) { _, new in new }
        }
        let path = light.isRoom
            ? "groups/\(light.id.dropFirst("group-".count))/action"
            : "lights/\(light.id.dropFirst("light-".count))/state"
        let didSet = await Self.requestJSON(method: "PUT", url: "\(baseURL)/\(path)", body: state)?.1 == 200
        await refreshHueLights()
        return didSet
    }

    private static func hueColor(named colorName: String) -> [String: Any] {
        switch colorName.lowercased() {
        case "red": return ["hue": 0, "sat": 254]
        case "orange": return ["hue": 6000, "sat": 254]
        case "yellow": return ["hue": 12000, "sat": 254]
        case "green": return ["hue": 25500, "sat": 254]
        case "cyan", "teal": return ["hue": 33000, "sat": 254]
        case "blue": return ["hue": 46920, "sat": 254]
        case "purple", "violet": return ["hue": 50000, "sat": 254]
        case "pink", "magenta": return ["hue": 56100, "sat": 254]
        case "warm", "warm white": return ["ct": 454]
        case "cool", "cool white", "daylight": return ["ct": 200]
        default: return ["ct": 300]   // white
        }
    }

    // MARK: - Home Assistant

    func connectHomeAssistant(url rawURL: String, token: String) async -> String? {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (_, statusCode) = await Self.requestJSON(method: "GET", url: "\(url)/api/", token: trimmedToken) else {
            return "Home Assistant didn't answer at \(url)."
        }
        guard statusCode == 200 else {
            return statusCode == 401 ? "Home Assistant didn't accept that token." : "Home Assistant answered with error \(statusCode)."
        }
        setup.homeAssistantURL = url
        secrets.homeAssistantToken = trimmedToken
        saveSetup()
        saveSecrets()
        foundDevices.removeAll { $0.kind == .homeAssistant }
        await refreshHomeAssistant()
        return nil
    }

    func disconnectHomeAssistant() {
        setup.homeAssistantURL = nil
        secrets.homeAssistantToken = nil
        homeAssistantEntities = []
        saveSetup()
        saveSecrets()
    }

    func refreshHomeAssistant() async {
        guard let url = setup.homeAssistantURL, let token = secrets.homeAssistantToken,
              let (json, _) = await Self.requestJSON(method: "GET", url: "\(url)/api/states", token: token),
              let states = json as? [[String: Any]] else { return }
        homeAssistantEntities = states.compactMap { entity in
            guard let entityID = entity["entity_id"] as? String,
                  Self.usefulDomains.contains(String(entityID.split(separator: ".").first ?? "")) else { return nil }
            let attributes = entity["attributes"] as? [String: Any]
            return HomeAssistantEntity(
                entityID: entityID,
                name: attributes?["friendly_name"] as? String ?? entityID,
                state: entity["state"] as? String ?? "unknown"
            )
        }
        .sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
    }

    func callHomeAssistant(domain: String, service: String, entityID: String, extra: [String: Any] = [:]) async -> Bool {
        guard let url = setup.homeAssistantURL, let token = secrets.homeAssistantToken else { return false }
        var body = extra
        body["entity_id"] = entityID
        let statusCode = await Self.requestJSON(method: "POST", url: "\(url)/api/services/\(domain)/\(service)", body: body, token: token)?.1
        return statusCode == 200
    }

    private func homeAssistantCameraImage(entityID: String) async -> Data? {
        guard let url = setup.homeAssistantURL, let token = secrets.homeAssistantToken,
              let requestURL = URL(string: "\(url)/api/camera_proxy/\(entityID)") else { return nil }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Voice tools

    static let functionNames: Set<String> = ["home_devices", "control_device", "tv_task"]

    static var functionDeclarations: [[String: Any]] {
        [
            [
                "name": "home_devices",
                "description": "List the user's smart home: TVs (and what they're showing), lights, plugs, blinds, locks, thermostats, vacuums, speakers, scenes and cameras, with their state. Use it before controlling something you haven't seen yet, or when asked what's on or what's connected.",
                "parameters": ["type": "OBJECT", "properties": [:]]
            ],
            [
                "name": "control_device",
                "description": "Control one smart home device right away: lights (on, off, brightness, color), plugs and switches, blinds and garage doors (open, close), locks, thermostats (temperature), vacuums (start, dock), scenes (on), speakers and TVs (play_pause, volume, mute, press a remote button, type, open an app or a link, mirror the TV into a window on the Mac), or look at a camera or a TV's screen and answer a question about it. For unlock, opening a garage door or turning off an alarm, ask the user first and pass confirmed true.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "device": ["type": "STRING", "description": "The device's or room's name, like 'living room lights' or 'TV'."],
                        "action": ["type": "STRING", "enum": [
                            "on", "off", "toggle", "brightness", "color", "temperature", "open", "close", "stop", "lock", "unlock",
                            "start", "dock", "play_pause", "volume_up", "volume_down", "mute", "press", "type", "open_app", "open_link",
                            "mirror", "stop_mirroring", "look"
                        ]],
                        "value": ["type": "STRING", "description": "brightness 0-100, a color name, a temperature, a remote button (\(DottieTV.remoteKeyNames.joined(separator: ", "))), text to type, an app name, a link, or the question for look."],
                        "confirmed": ["type": "BOOLEAN", "description": "true once the user said yes to unlocking or opening."]
                    ],
                    "required": ["device", "action"]
                ]
            ],
            [
                "name": "tv_task",
                "description": "Do something on a TV that takes several steps, looking at its screen as it goes, like 'put on the next episode of Bluey', 'find a cooking video on YouTube', 'turn on subtitles' or 'what's on the TV?'. Say a few words, then stop; the result comes back in a later message.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "task": ["type": "STRING", "description": "The whole job, with the details the user gave."],
                        "tv": ["type": "STRING", "description": "Which TV, if the user has several."]
                    ],
                    "required": ["task"]
                ]
            ]
        ]
    }

    /// For voice Dottie's prompt: what's set up.
    var promptSummary: String {
        var lines: [String] = []
        if !setup.tvs.isEmpty {
            lines.append("TVs: " + setup.tvs.map { "\($0.name)\(canSee($0) ? "" : " (can't see its screen)")" }.joined(separator: ", "))
        }
        if isHueConnected { lines.append("Philips Hue lights are connected.") }
        if isHomeAssistantConnected { lines.append("Home Assistant is connected (\(homeAssistantEntities.count) devices).") }
        return lines.joined(separator: "\n")
    }

    func listForVoice() async -> String {
        await refresh()
        var sections: [String] = []
        if !setup.tvs.isEmpty {
            sections.append("TVs:\n" + setup.tvs.map { tv in
                "- \(tv.name): \(tvStatus[tv.id] ?? "unknown")\(canSee(tv) ? "" : ", can't see its screen")"
            }.joined(separator: "\n"))
        }
        if !lights.isEmpty {
            sections.append("Hue lights:\n" + lights.map { light in
                "- \(light.name)\(light.isRoom ? " (room)" : ""): \(light.isOn ? "on" : "off")\(light.isOn ? light.brightnessPercent.map { " \($0)%" } ?? "" : "")"
            }.joined(separator: "\n"))
        }
        if !homeAssistantEntities.isEmpty {
            sections.append("Home Assistant:\n" + homeAssistantEntities.prefix(80).map { "- \($0.name) (\($0.domain)): \($0.state)" }.joined(separator: "\n"))
        }
        sections.append("Apple Home: run the user's shortcuts for HomeKit scenes (list_shortcuts, run_shortcut), or open the Home app and use do_task_on_screen.")
        if setup.tvs.isEmpty && lights.isEmpty && homeAssistantEntities.isEmpty {
            sections.insert("nothing is set up yet. the user can add TVs, Hue lights and Home Assistant in Dottie's Home window, under Smart Home.", at: 0)
        }
        return sections.joined(separator: "\n\n")
    }

    func control(arguments: [String: Any]) async -> String {
        let deviceName = ((arguments["device"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let action = ((arguments["action"] as? String) ?? "").lowercased()
        let value = (arguments["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isConfirmed = (arguments["confirmed"] as? Bool) ?? false

        if let tv = matchTV(deviceName) {
            return await control(tv: tv, action: action, value: value)
        }
        if lights.isEmpty && isHueConnected { await refreshHueLights() }
        if let light = Self.bestMatch(deviceName, in: lights, name: \.name) {
            switch action {
            case "on": return await setHue(light, isOn: true) ? "\(light.name) on." : "the Hue bridge didn't answer."
            case "off": return await setHue(light, isOn: false) ? "\(light.name) off." : "the Hue bridge didn't answer."
            case "toggle": return await setHue(light, isOn: !light.isOn) ? "\(light.name) \(light.isOn ? "off" : "on")." : "the Hue bridge didn't answer."
            case "brightness":
                let percent = Int(value.filter(\.isNumber)) ?? 100
                return await setHue(light, brightnessPercent: percent) ? "\(light.name) at \(percent)%." : "the Hue bridge didn't answer."
            case "color":
                return await setHue(light, colorName: value) ? "\(light.name) is \(value) now." : "the Hue bridge didn't answer."
            default:
                return "Hue lights can be turned on or off, dimmed or colored."
            }
        }
        if homeAssistantEntities.isEmpty && isHomeAssistantConnected { await refreshHomeAssistant() }
        if let entity = Self.bestMatch(deviceName, in: homeAssistantEntities, name: \.name) {
            return await control(entity: entity, action: action, value: value, isConfirmed: isConfirmed)
        }
        if setup.tvs.isEmpty && !isHueConnected && !isHomeAssistantConnected {
            return "no smart home devices are set up yet. tell the user they can add their TV, Hue lights or Home Assistant in Dottie's Home window, under Smart Home. for Apple Home devices, a shortcut works (run_shortcut)."
        }
        return "couldn't find \(deviceName). call home_devices to see the names."
    }

    private func control(tv: TV, action: String, value: String) async -> String {
        switch action {
        case "press":
            let keyName = value.lowercased().replacingOccurrences(of: " ", with: "_")
            return await press(keyName, on: tv) ? "pressed \(keyName) on \(tv.name)." : "couldn't press \(value) on \(tv.name)."
        case "on":
            var didWork = await press("wake", on: tv)
            if !didWork { didWork = await press("power", on: tv) }
            return didWork ? "\(tv.name) on." : "couldn't reach \(tv.name)."
        case "off":
            var didWork = await press("sleep", on: tv)
            if !didWork { didWork = await press("power", on: tv) }
            return didWork ? "\(tv.name) off." : "couldn't reach \(tv.name)."
        case "toggle":
            return await press("power", on: tv) ? "pressed power on \(tv.name)." : "couldn't reach \(tv.name)."
        case "play_pause", "volume_up", "volume_down", "mute":
            return await press(action, on: tv) ? "done." : "couldn't reach \(tv.name)."
        case "type":
            return await type(value, on: tv) ? "typed it on \(tv.name)." : "couldn't type on \(tv.name)."
        case "open_app":
            return await openApp(value, on: tv)
        case "open_link":
            guard tv.kind == .android else { return "only Android and Google TVs can open links." }
            return await DottieTV.adbOpenURL(serial: tv.address, url: value) ? "opened it on \(tv.name)." : "couldn't open it."
        case "mirror":
            return mirror(tv) ?? "\(tv.name) is in a window on the Mac now; you can use it like any app."
        case "stop_mirroring":
            DottieTV.stopMirroring(serial: tv.address)
            return "closed the TV window."
        case "look":
            guard let screenData = await screen(of: tv) else { return "can't see \(tv.name)'s screen." }
            return await Self.describe(imageData: screenData, question: value.isEmpty ? "What's on this TV screen?" : value)
        default:
            return "\(tv.name) is a TV: use press, type, open_app, open_link, mirror, look, or tv_task for bigger jobs."
        }
    }

    private func control(entity: HomeAssistantEntity, action: String, value: String, isConfirmed: Bool) async -> String {
        let domain = entity.domain
        let number = Double(value.filter { $0.isNumber || $0 == "." })
        if action == "look" {
            guard domain == "camera", let image = await homeAssistantCameraImage(entityID: entity.entityID) else {
                return "couldn't get a picture from \(entity.name)."
            }
            return await Self.describe(imageData: image, question: value.isEmpty ? "What do you see on this camera?" : value)
        }
        // Things that let people in need the user's yes first.
        let isRisky = action == "unlock"
            || (domain == "cover" && (action == "open" || action == "on") && entity.name.lowercased().contains("garage"))
            || (domain == "alarm_control_panel" && action == "off")
        if isRisky && !isConfirmed {
            return "ask the user first: \(action) \(entity.name)? if they say yes, call again with confirmed true."
        }
        let call: (service: String, extra: [String: Any])?
        switch (action, domain) {
        case ("unlock", _): call = ("unlock", [:])
        case ("off", "alarm_control_panel"): call = ("alarm_disarm", [:])
        case ("lock", _): call = ("lock", [:])
        case ("open", _): call = ("open_cover", [:])
        case ("close", _): call = ("close_cover", [:])
        case ("stop", "cover"): call = ("stop_cover", [:])
        case ("stop", "vacuum"), ("stop", "media_player"): call = (domain == "vacuum" ? "stop" : "media_stop", [:])
        case ("start", "vacuum"): call = ("start", [:])
        case ("dock", "vacuum"): call = ("return_to_base", [:])
        case ("brightness", "light"): call = ("turn_on", ["brightness_pct": Int(number ?? 100)])
        case ("color", "light"): call = ("turn_on", ["color_name": value.lowercased()])
        case ("temperature", _): call = ("set_temperature", ["temperature": number ?? 21])
        case ("play_pause", _): call = ("media_play_pause", [:])
        case ("volume_up", _), ("volume_down", _): call = (action, [:])
        case ("mute", _): call = ("volume_mute", ["is_volume_muted": true])
        case ("on", "scene"), ("on", "script"): call = ("turn_on", [:])
        case ("on", "cover"): call = ("open_cover", [:])
        case ("off", "cover"): call = ("close_cover", [:])
        case ("on", _): call = ("turn_on", [:])
        case ("off", _): call = ("turn_off", [:])
        case ("toggle", _): call = ("toggle", [:])
        default: call = nil
        }
        guard let call else { return "\(entity.name) can't do \(action)." }
        let didWork = await callHomeAssistant(domain: domain, service: call.service, entityID: entity.entityID, extra: call.extra)
        if didWork { Task { await refreshHomeAssistant() } }
        return didWork ? "done: \(entity.name) \(action)\(value.isEmpty ? "" : " \(value)")." : "Home Assistant couldn't do that."
    }

    func tv(named name: String?) -> TV? {
        guard let name, !name.isEmpty else { return setup.tvs.first }
        return matchTV(name) ?? (setup.tvs.count == 1 ? setup.tvs.first : nil)
    }

    private func matchTV(_ name: String) -> TV? {
        if let tv = Self.bestMatch(name, in: setup.tvs, name: \.name) { return tv }
        let lowered = name.lowercased()
        // "the TV" with one TV set up.
        if setup.tvs.count == 1, lowered.contains("tv") || lowered.contains("telly") || lowered.contains("roku") || lowered.contains("television") {
            return setup.tvs.first
        }
        return nil
    }

    /// The item whose name shares the most words with what was said.
    private static func bestMatch<Item>(_ spokenName: String, in items: [Item], name: KeyPath<Item, String>) -> Item? {
        let spokenWords = Set(spokenName.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(["the", "my", "a", "in", "of", "please"])
        guard !spokenWords.isEmpty else { return nil }
        if let exact = items.first(where: { $0[keyPath: name].lowercased() == spokenName.lowercased() }) { return exact }
        let scored = items.map { item -> (Item, Int) in
            let itemWords = Set(item[keyPath: name].lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return (item, itemWords.intersection(spokenWords).count)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    // MARK: - Helpers

    /// Asks Gemini about a picture (a TV screen or a camera).
    private static func describe(imageData: Data, question: String) async -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280
              ] as CFDictionary),
              let jpegData = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            return "couldn't read the picture."
        }
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        let body: [String: Any] = [
            "model": "gemini-3.5-flash-lite",
            "contents": [["role": "user", "parts": [
                ["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]],
                ["text": question + " Answer in one or two short sentences."]
            ]]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return "couldn't look right now." }
        let answer = GeminiServerSentEvents.text(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? "couldn't tell." : answer
    }

    private static func requestJSON(method: String, url: String, body: Any? = nil, token: String? = nil) async -> (Any?, Int)? {
        guard let requestURL = URL(string: url) else { return nil }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = 8
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data), (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func saveSetup() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(setup) {
            try? data.write(to: setupURL, options: .atomic)
        }
    }

    private func saveSecrets() {
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        FileManager.default.createFile(atPath: secretsURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

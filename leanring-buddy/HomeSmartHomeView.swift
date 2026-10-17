//
//  HomeSmartHomeView.swift
//  leanring-buddy
//
//  Home → Smart Home: set up the TVs, lights and Home Assistant Dottie
//  controls (DottieSmartHome), with a small remote to try each TV.
//

import AppKit
import AVFoundation
import SwiftUI

struct HomeSmartHomeView: View {
    @ObservedObject var smartHome: DottieSmartHome

    @State private var newTVName = ""
    @State private var newTVAddress = ""
    @State private var pairingAddress = ""
    @State private var pairingCode = ""
    @State private var hueAddress = ""
    @State private var homeAssistantURL = ""
    @State private var homeAssistantToken = ""
    @State private var anyTVName = ""
    @State private var anyTVCaptureID = ""
    @State private var anyTVKeyboardPort = ""
    @State private var remoteTVID: UUID?
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Smart Home")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Dottie runs your house: \u{201C}put YouTube on the TV\u{201D}, \u{201C}dim the living room to 30\u{201D}, \u{201C}what's on the front door camera?\u{201D}, \u{201C}put on the next episode of Bluey\u{201D}. Add your things here.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let statusMessage = smartHome.statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                findCard
                tvsCard
                addTVCard
                hueCard
                homeAssistantCard
                HomeCard(title: "Apple Home") {
                    HomeHint("Apple doesn't let Mac apps control HomeKit directly. Make a shortcut for each scene or device in the Shortcuts app (\u{201C}Movie night\u{201D}, \u{201C}Porch light on\u{201D}) and Dottie runs it by name, or ask her to do it in the Home app and she works it on screen. Home Assistant can also bring HomeKit and Matter devices in.")
                    Button("Open the Home app") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Home.app"))
                    }
                    .controlSize(.small)
                }
            }
            .padding(24)
        }
        .task { await smartHome.refresh() }
    }

    // MARK: - Finding

    private var findCard: some View {
        HomeCard(title: "Find on your Wi-Fi") {
            HStack {
                Button(smartHome.isSearching ? "Looking…" : "Find TVs, lights and Home Assistant") { smartHome.searchNetwork() }
                    .disabled(smartHome.isSearching)
                if smartHome.isSearching { ProgressView().controlSize(.small) }
            }
            ForEach(smartHome.foundDevices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textPrimary)
                        Text("\(label(for: device.kind)) · \(device.host)").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer()
                    Button("Add") { add(device) }
                        .disabled(isWorking)
                }
            }
        }
    }

    private func label(for kind: DottieSmartHome.FoundDevice.Kind) -> String {
        switch kind {
        case .androidTV: return "Android / Google TV"
        case .roku: return "Roku"
        case .hueBridge: return "Hue bridge"
        case .homeAssistant: return "Home Assistant"
        }
    }

    private func add(_ device: DottieSmartHome.FoundDevice) {
        switch device.kind {
        case .androidTV:
            newTVName = device.name
            newTVAddress = device.host
            run { await smartHome.addAndroidTV(name: device.name, address: device.host) }
        case .roku:
            run { await smartHome.addRoku(name: device.name, host: device.host) }
        case .hueBridge:
            hueAddress = device.host
            run { await smartHome.connectHue(bridgeAddress: device.host) }
        case .homeAssistant:
            homeAssistantURL = device.url ?? "http://\(device.host):8123"
            smartHome.statusMessage = "Paste a long-lived access token for Home Assistant below (your profile in Home Assistant → Security → Create token)."
        }
    }

    // MARK: - TVs

    private var tvsCard: some View {
        HomeCard(title: "TVs") {
            if smartHome.setup.tvs.isEmpty {
                HomeHint("No TVs yet. Find them above, or add one below.")
            }
            ForEach(smartHome.setup.tvs) { tv in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tv.name).font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                            Text(smartHome.tvStatus[tv.id] ?? kindLabel(tv.kind))
                                .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                        }
                        Spacer()
                        Button(remoteTVID == tv.id ? "Hide remote" : "Remote") {
                            remoteTVID = remoteTVID == tv.id ? nil : tv.id
                        }
                        if tv.kind == .android {
                            Button("Show on Mac") {
                                smartHome.statusMessage = smartHome.mirror(tv) ?? "\(tv.name) is open in a window."
                            }
                        }
                        Button("Remove") { smartHome.removeTV(tv) }
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .controlSize(.small)
                    if remoteTVID == tv.id {
                        remote(for: tv)
                    }
                }
            }
        }
    }

    private func kindLabel(_ kind: DottieSmartHome.TV.Kind) -> String {
        switch kind {
        case .android: return "Android / Google / Fire TV"
        case .roku: return "Roku"
        case .anyTV: return "Capture card and keyboard adapter"
        }
    }

    private func remote(for tv: DottieSmartHome.TV) -> some View {
        let button: (String, String) -> AnyView = { title, key in
            AnyView(Button(title) { Task { _ = await smartHome.press(key, on: tv) } }.frame(minWidth: 44))
        }
        return VStack(spacing: 6) {
            HStack(spacing: 6) { button("Home", "home"); button("▲", "up"); button("Back", "back") }
            HStack(spacing: 6) { button("◀", "left"); button("OK", "ok"); button("▶", "right") }
            HStack(spacing: 6) { button("Vol −", "volume_down"); button("▼", "down"); button("Vol +", "volume_up") }
            HStack(spacing: 6) { button("⏯", "play_pause"); button("Mute", "mute"); button("Power", "power") }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Adding a TV by hand

    private var addTVCard: some View {
        HomeCard(title: "Add a TV") {
            HStack {
                Text(DottieTV.isADBInstalled && DottieTV.isScrcpyInstalled ? "TV tools are installed." : "Android TVs need adb and scrcpy (free, from Homebrew).")
                    .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                Spacer()
                if !(DottieTV.isADBInstalled && DottieTV.isScrcpyInstalled) {
                    Button(smartHome.isInstallingTVTools ? "Installing…" : "Install") { Task { await smartHome.installTVTools() } }
                        .disabled(smartHome.isInstallingTVTools)
                        .controlSize(.small)
                }
            }
            HomeHint("Android, Google or Fire TV: on the TV, open Settings → About and click Build 7 times, then turn on Network debugging (or Wireless debugging) in Developer options. Type its address (Settings → Network), press Connect and pick Allow on the TV.")
            HStack {
                TextField("Name, like Living room TV", text: $newTVName).textFieldStyle(.roundedBorder)
                TextField("Address, like 192.168.1.40", text: $newTVAddress).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Connect Android TV") {
                    let name = newTVName, address = newTVAddress.trimmingCharacters(in: .whitespaces)
                    run { await smartHome.addAndroidTV(name: name, address: address) }
                }
                Button("Add Roku") {
                    let name = newTVName, address = newTVAddress.trimmingCharacters(in: .whitespaces)
                    run { await smartHome.addRoku(name: name, host: address) }
                }
            }
            .controlSize(.small)
            .disabled(newTVAddress.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            HomeHint("Wireless debugging asks to pair once: on the TV choose Pair device with pairing code, then type the address and code it shows here, then Connect with the address under Wireless debugging.")
            HStack {
                TextField("Pairing address (ip:port)", text: $pairingAddress).textFieldStyle(.roundedBorder)
                TextField("Code", text: $pairingCode).textFieldStyle(.roundedBorder).frame(width: 90)
                Button("Pair") {
                    let address = pairingAddress.trimmingCharacters(in: .whitespaces), code = pairingCode
                    run {
                        let problem = await smartHome.pairAndroidTV(pairingAddress: address, code: code)
                        return problem ?? "Paired. Now connect with the address shown under Wireless debugging."
                    }
                }
                .controlSize(.small)
                .disabled(pairingAddress.isEmpty || pairingCode.isEmpty || isWorking)
            }

            Divider()
            Text("Any other TV").font(.system(size: 12, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            HomeHint("Plug the TV's HDMI out into a USB capture card so Dottie can see it, and a CH9329 USB keyboard adapter into the TV so she can press keys. Either works alone: a Roku plus a capture card is a good pair.")
            TextField("Name", text: $anyTVName).textFieldStyle(.roundedBorder)
            Picker("Capture card", selection: $anyTVCaptureID) {
                Text("None").tag("")
                ForEach(DottieTV.captureDevices(), id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            Picker("Keyboard adapter", selection: $anyTVKeyboardPort) {
                Text("None").tag("")
                ForEach(DottieTV.keyboardAdapterPorts(), id: \.self) { port in
                    Text(port).tag(port)
                }
            }
            HStack {
                Button("Add this TV") {
                    smartHome.addAnyTV(
                        name: anyTVName,
                        captureDeviceID: anyTVCaptureID.isEmpty ? nil : anyTVCaptureID,
                        keyboardPort: anyTVKeyboardPort.isEmpty ? nil : anyTVKeyboardPort
                    )
                    anyTVName = ""
                }
                .disabled(anyTVCaptureID.isEmpty && anyTVKeyboardPort.isEmpty)
                if let roku = smartHome.setup.tvs.first(where: { $0.kind == .roku && $0.captureDeviceID == nil }), !anyTVCaptureID.isEmpty {
                    Button("Use this card to see \(roku.name)") {
                        var updatedRoku = roku
                        updatedRoku.captureDeviceID = anyTVCaptureID
                        smartHome.updateTV(updatedRoku)
                    }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Hue

    private var hueCard: some View {
        HomeCard(title: "Philips Hue") {
            if smartHome.isHueConnected {
                ForEach(smartHome.lights) { light in
                    HStack {
                        Text(light.isRoom ? "\(light.name) (room)" : light.name)
                            .font(.system(size: 12)).foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        if light.isOn, let brightness = light.brightnessPercent {
                            Text("\(brightness)%").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                        }
                        Toggle("", isOn: Binding(
                            get: { light.isOn },
                            set: { newValue in Task { _ = await smartHome.setHue(light, isOn: newValue) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                Button("Disconnect Hue") { smartHome.disconnectHue() }
                    .controlSize(.small)
            } else {
                HomeHint("Find the bridge above, or type its address. Press the round button on top of the bridge, then Connect.")
                HStack {
                    TextField("Bridge address", text: $hueAddress).textFieldStyle(.roundedBorder)
                    Button("Connect") {
                        let address = hueAddress.trimmingCharacters(in: .whitespaces)
                        run { await smartHome.connectHue(bridgeAddress: address) }
                    }
                        .disabled(hueAddress.isEmpty || isWorking)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Home Assistant

    private var homeAssistantCard: some View {
        HomeCard(title: "Home Assistant") {
            if smartHome.isHomeAssistantConnected {
                Text("\(smartHome.homeAssistantEntities.count) devices: lights, plugs, blinds, locks, thermostats, vacuums, speakers, scenes and cameras.")
                    .font(.system(size: 12)).foregroundColor(DS.Colors.textSecondary)
                let domainCounts = Dictionary(grouping: smartHome.homeAssistantEntities, by: \.domain).mapValues(\.count)
                Text(domainCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                Button("Disconnect Home Assistant") { smartHome.disconnectHomeAssistant() }
                    .controlSize(.small)
            } else {
                HomeHint("Home Assistant connects almost any smart device (and HomeKit or Matter ones). Paste its address and a long-lived access token from your Home Assistant profile.")
                TextField("Address, like http://homeassistant.local:8123", text: $homeAssistantURL).textFieldStyle(.roundedBorder)
                SecureField("Long-lived access token", text: $homeAssistantToken).textFieldStyle(.roundedBorder)
                Button("Connect") {
                    let url = homeAssistantURL
                    let token = homeAssistantToken
                    homeAssistantToken = ""
                    run { await smartHome.connectHomeAssistant(url: url, token: token) }
                }
                .controlSize(.small)
                .disabled(homeAssistantURL.isEmpty || homeAssistantToken.isEmpty || isWorking)
            }
        }
    }

    // MARK: - Helpers

    /// Runs a setup step; a returned message is shown, nil means it worked.
    private func run(_ step: @escaping () async -> String?) {
        isWorking = true
        smartHome.statusMessage = "Working on it…"
        Task {
            let message = await step()
            isWorking = false
            smartHome.statusMessage = message ?? "Done."
            await smartHome.refresh()
        }
    }
}

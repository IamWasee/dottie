//
//  HomeSpaceRootView.swift
//  leanring-buddy
//
//  Clicky's Home window: the conversation so far, background Clickys, their
//  skills and settings, in one place. Shipped Clicky's Home
//  (HomeSpaceRootView) also holds suggestions; those arrive with a later
//  phase (see ROADMAP.md).
//  HomeWindowManager at the bottom owns the NSWindow.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeSpaceRootView: View {
    enum HomeSection: String, CaseIterable, Identifiable {
        case conversation = "Conversation"
        case clickys = "Dots"
        case projects = "Projects"
        case pictures = "Pictures"
        case smartReplays = "Smart Replays"
        case smartHome = "Smart Home"
        case skills = "Skills"
        case tools = "Tools"
        case brain = "Brain"
        case meetings = "Meetings"
        case phone = "Phone"
        case profile = "Profile"
        case settings = "Settings"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .conversation: return "bubble.left.and.bubble.right.fill"
            case .clickys: return "person.2.fill"
            case .projects: return "folder.fill"
            case .pictures: return "photo.on.rectangle.angled"
            case .smartReplays: return "play.rectangle.on.rectangle"
            case .smartHome: return "house.fill"
            case .skills: return "sparkles"
            case .tools: return "wrench.and.screwdriver.fill"
            case .brain: return "brain.head.profile"
            case .meetings: return "waveform"
            case .phone: return "iphone"
            case .profile: return "star.circle.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    /// The sidebar's headings, Talk / Make / You, each with its pages.
    enum SidebarGroup: String, CaseIterable {
        case talk = "Talk"
        case make = "Make"
        case you = "You"

        var sections: [HomeSection] {
            switch self {
            case .talk: return [.conversation, .clickys, .projects, .meetings, .phone]
            case .make: return [.pictures, .smartReplays, .skills, .tools, .smartHome]
            case .you: return [.brain, .profile, .settings]
            }
        }
    }

    // Sidebar layout. DottieSelfKnowledge uses these to point at a row when
    // accessibility can't find it, so the layout below must match them.
    static let sidebarWidth: CGFloat = 200
    static let sidebarTopInset: CGFloat = 8
    static let sidebarGroupHeaderHeight: CGFloat = 22
    static let sidebarRowHeight: CGFloat = 28
    static let sidebarRowSpacing: CGFloat = 2
    static let sidebarGroupSpacing: CGFloat = 14

    /// How far below the top of the window's content a section's sidebar
    /// row starts.
    static func sidebarRowTopOffset(for section: HomeSection) -> CGFloat? {
        var groupTopOffset = sidebarTopInset
        for group in SidebarGroup.allCases {
            let firstRowTopOffset = groupTopOffset + sidebarGroupHeaderHeight + sidebarRowSpacing
            if let rowIndex = group.sections.firstIndex(of: section) {
                return firstRowTopOffset + CGFloat(rowIndex) * (sidebarRowHeight + sidebarRowSpacing)
            }
            let groupRowsHeight = CGFloat(group.sections.count) * (sidebarRowHeight + sidebarRowSpacing) - sidebarRowSpacing
            groupTopOffset = firstRowTopOffset + groupRowsHeight + sidebarGroupSpacing
        }
        return nil
    }

    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var clickyRoster: ClickyRoster
    @State private var selectedSection: HomeSection = .conversation
    @State private var hoveredSidebarSection: HomeSection?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch selectedSection {
                case .conversation:
                    HomeConversationView(
                        companionManager: companionManager,
                        conversationStore: conversationStore,
                        shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor
                    )
                case .clickys:
                    HomeClickysView(clickyRoster: clickyRoster)
                case .projects:
                    HomeProjectsView(projects: companionManager.projects, clickyRoster: clickyRoster)
                case .pictures:
                    HomePicturesView(imageMemory: companionManager.imageMemory)
                case .smartReplays:
                    HomeSmartReplaysView(smartReplayStore: DottieSmartReplayStore.shared)
                case .smartHome:
                    HomeSmartHomeView(smartHome: companionManager.smartHome)
                case .skills:
                    HomeSkillsView(clickyRoster: clickyRoster, skillLibrary: clickyRoster.skillLibrary)
                case .tools:
                    HomeToolsView()
                case .brain:
                    HomeBrainView(brain: companionManager.brain)
                case .meetings:
                    HomeMeetingsView(meetingRecorder: companionManager.meetingRecorder)
                case .phone:
                    HomePhoneView(phoneBridge: companionManager.phoneBridge)
                case .profile:
                    HomeProfileView(companionManager: companionManager)
                case .settings:
                    HomeSettingsView(
                        companionManager: companionManager,
                        conversationStore: conversationStore,
                        shortcutMonitor: companionManager.globalPushToTalkShortcutMonitor
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Colors.background)
        }
        // Follows the Mac's light or dark appearance, like a built-in app.
        .onReceive(clickyRoster.$agentIDRequestedInHome) { requestedAgentID in
            // The notch asked to show a Dot; HomeClickysView selects it.
            if requestedAgentID != nil {
                selectedSection = .clickys
            }
        }
        .onReceive(DottieHomeNavigator.shared.$requestedSection) { requestedSection in
            // Dottie opened a page herself (about_me open, or a walkthrough).
            guard let requestedSection else { return }
            selectedSection = requestedSection
            DottieHomeNavigator.shared.requestedSection = nil
        }
    }

    /// A Mac-style sidebar on the system's translucent sidebar material:
    /// labeled pages under Talk, Make and You.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Self.sidebarGroupSpacing) {
            ForEach(SidebarGroup.allCases, id: \.self) { sidebarGroup in
                VStack(alignment: .leading, spacing: Self.sidebarRowSpacing) {
                    Text(sidebarGroup.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .frame(height: Self.sidebarGroupHeaderHeight, alignment: .bottomLeading)
                    ForEach(sidebarGroup.sections) { section in
                        sidebarRow(for: section)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Self.sidebarTopInset)
        .padding(.horizontal, 10)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // The material runs up under the transparent title bar, as in Finder.
        .background(DSVisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    private func sidebarRow(for section: HomeSection) -> some View {
        let isSelected = selectedSection == section
        let isHovered = hoveredSidebarSection == section
        return Button(action: { selectedSection = section }) {
            HStack(spacing: 8) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.accentText)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? DS.Colors.accent : (isHovered ? DS.Colors.surface3.opacity(0.7) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            hoveredSidebarSection = isHovering ? section : (hoveredSidebarSection == section ? nil : hoveredSidebarSection)
        }
        .accessibilityLabel(Text(section.rawValue))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Conversation

private struct HomeConversationView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor
    @State private var typedMessage = ""
    /// Pictures waiting to go with the next message.
    @State private var attachedImages: [AttachedImage] = []
    @State private var isDropTargeted = false
    /// Catches ⌘V with a picture on the clipboard. The text field takes
    /// ⌘V for itself, so .onPasteCommand never sees pictures.
    @State private var pasteKeyMonitor: Any?

    private struct AttachedImage: Identifiable {
        let id = UUID()
        let data: Data
        let thumbnail: NSImage
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversation")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text("hold \(shortcutMonitor.talkHotkey.displayText) to talk")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(DS.Colors.borderSubtle)

            if conversationStore.entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(conversationStore.entries) { entry in
                                HomeConversationEntryView(entry: entry, imageFolderURL: companionManager.imageMemory.folderURL)
                                    .deletableRow(copyText: entry.clickyText.isEmpty ? entry.userText : entry.clickyText) {
                                        withAnimation { companionManager.forgetConversationEntry(entry.id) }
                                    }
                                    .id(entry.id)
                            }
                        }
                        .padding(20)
                    }
                    .onAppear {
                        scrollProxy.scrollTo(conversationStore.entries.last?.id, anchor: .bottom)
                    }
                    .onChange(of: conversationStore.entries.count) { _, _ in
                        withAnimation {
                            scrollProxy.scrollTo(conversationStore.entries.last?.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider().background(DS.Colors.borderSubtle)
            composer
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.accent, lineWidth: 2)
                .padding(4)
                .opacity(isDropTargeted ? 1 : 0)
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            loadImages(from: providers)
            return true
        }
        .onAppear(perform: startWatchingForPaste)
        .onDisappear(perform: stopWatchingForPaste)
    }

    private func startWatchingForPaste() {
        guard pasteKeyMonitor == nil else { return }
        pasteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  event.window?.isKeyWindow == true,
                  !(event.window is NSPanel) else { return event }
            let pastedImages = Self.imagesOnClipboard()
            guard !pastedImages.isEmpty else { return event }
            pastedImages.forEach(attach)
            return nil
        }
    }

    private func stopWatchingForPaste() {
        if let pasteKeyMonitor { NSEvent.removeMonitor(pasteKeyMonitor) }
        pasteKeyMonitor = nil
    }

    /// Picture files copied in Finder, or picture data (a screenshot or an
    /// image copied from a web page).
    private static func imagesOnClipboard() -> [Data] {
        let pasteboard = NSPasteboard.general
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let imageFiles = fileURLs.compactMap { url -> Data? in
            guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return nil }
            return data
        }
        if !imageFiles.isEmpty { return imageFiles }
        for imageType in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pasteboard.data(forType: imageType), NSImage(data: data) != nil { return [data] }
        }
        if let image = NSImage(pasteboard: pasteboard), let tiffData = image.tiffRepresentation {
            return [tiffData]
        }
        return []
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            NotchEyeView(mood: .idle)
                .padding(10)
                .background(Circle().fill(Color.black))
            Text("Nothing here yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Hold \(shortcutMonitor.talkHotkey.displayText) and ask Dottie about anything on your screen.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private var canSend: Bool {
        !typedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedImages) { attachedImage in
                            Image(nsImage: attachedImage.thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        attachedImages.removeAll { $0.id == attachedImage.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)
                                            .background(Circle().fill(Color.black.opacity(0.6)))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 5, y: -5)
                                }
                        }
                    }
                    .padding(.top, 6)
                }
                Text("Dottie saves pictures and remembers them by name, so later you can say \u{201C}go grab that\u{201D}.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            HStack(spacing: 10) {
                Button(action: pickImages) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 15))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Add a picture (or drop or paste one)")
                TextField(attachedImages.isEmpty ? "Type to Dottie" : "Say what it is, like \u{201C}this is my golden sword\u{201D}", text: $typedMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .onSubmit(sendTypedMessage)
                Button(action: sendTypedMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canSend ? DS.Colors.accent : DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: canSend)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            loadImages(from: providers)
        }
    }

    private func sendTypedMessage() {
        let messageText = typedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let imageDataList = attachedImages.map(\.data)
        typedMessage = ""
        attachedImages = []
        companionManager.sendTypedMessage(messageText, imageDataList: imageDataList)
    }

    private func pickImages() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.image]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.message = "Pick pictures for Dottie to remember"
        guard openPanel.runModal() == .OK else { return }
        for url in openPanel.urls {
            if let data = try? Data(contentsOf: url) { attach(data) }
        }
    }

    /// Dropped or pasted pictures: image files, or image data (a screenshot
    /// copied to the clipboard).
    private func loadImages(from providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
                    DispatchQueue.main.async { attach(data) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { attach(data) }
                }
            }
        }
    }

    private func attach(_ data: Data) {
        guard let thumbnail = NSImage(data: data), attachedImages.count < 6 else { return }
        attachedImages.append(AttachedImage(data: data, thumbnail: thumbnail))
    }
}

private struct HomeConversationEntryView: View {
    let entry: ConversationEntry
    let imageFolderURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imageFileNames = entry.imageFileNames, !imageFileNames.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 60)
                    ForEach(imageFileNames, id: \.self) { fileName in
                        if let image = NSImage(contentsOf: imageFolderURL.appendingPathComponent(fileName)) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 140, maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
            if !entry.userText.isEmpty {
                HStack {
                    Spacer(minLength: 60)
                    Text(entry.userText)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(DS.Colors.helpChatUserBubble)
                        )
                }
            }
            if !entry.clickyText.isEmpty {
                Text(entry.clickyText)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened) + (entry.inputKind == .typed ? " · typed" : " · voice"))
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

// MARK: - Settings

private struct HomeSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var shortcutMonitor: GlobalPushToTalkShortcutMonitor

    private let isCuaDriverInstalled = ClickyComputerUse.locateCuaDriverExecutable() != nil
    private let isCuaDriverBundled = ClickyComputerUse.isCuaDriverBundled
    // Same key ClickyComputerUse.isAlwaysAllowed reads.
    @AppStorage("clickyComputerUseAlwaysAllowed") private var isComputerUseAlwaysAllowed = false
    // Same keys ClickyDictationController reads.
    @AppStorage("clickyDictationEnabled") private var isDictationEnabled = true
    @AppStorage(ClickyNotifications.enabledDefaultsKey) private var areDotNotificationsEnabled = true
    @AppStorage(ScreenAnnotationManager.enabledDefaultsKey) private var isScreenAnnotationEnabled = true
    @AppStorage(ClickyDictationController.customWordsDefaultsKey) private var dictationCustomWords = ""
    @AppStorage(ClickyWorkerConfiguration.userWorkerBaseURLDefaultsKey) private var userWorkerBaseURL = ""
    @AppStorage(ClickyWorkerConfiguration.userAppSharedSecretDefaultsKey) private var userAppSharedSecret = ""
    @State private var serverCheckMessage: String?
    @State private var learnedTipCount = DottieScreenLessons.shared.count
    @State private var isCheckingServer = false
    /// What's typed in the search field at the top of Settings. Empty shows every section.
    @State private var settingsSearchText = ""
    @AppStorage(DictationDictionary.learnsCorrectionsDefaultsKey) private var learnsDictationCorrections = true
    @AppStorage(DictationLanguageCatalog.autoDetectDefaultsKey) private var isDictationLanguageAutoDetected = true
    @AppStorage(DictationLiveTranscriber.enabledDefaultsKey) private var showsDictationLiveText = true
    @AppStorage(DictationLanguageCatalog.languageCodeDefaultsKey) private var dictationLanguageCode = DictationLanguageCatalog.defaultLanguageCode
    @ObservedObject private var dictationDictionary = DictationDictionary.shared

    var body: some View {
        ScrollViewReader { scrollProxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                settingsSearchField

                if !settingsSearchText.isEmpty && !hasAnySettingsGroupMatchingSearch {
                    Text("No settings match \"\(settingsSearchText)\".")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                settingsGroup(title: "Permissions") {
                    HomePermissionsSettings()
                }

                settingsGroup(title: "Updates") {
                    HomeUpdateSettings()
                }
                settingsGroup(title: "Helpers: Claude via MausBot") { DottieMausBotSettingsCard() }

                settingsGroup(title: "Usage") {
                    HomeUsageSettings()
                }

                settingsGroup(title: "Check everything") {
                    HomeSelfCheckSettings()
                }

                settingsGroup(title: "Instant replays") {
                    HomeReplaySettings()
                }

                settingsGroup(title: "Voice") {
                    HomeVoiceChooser(companionManager: companionManager)
                    DottiePersonalitySettings(companionManager: companionManager)
                    settingsRow(label: "Voice mode") {
                        Text(companionManager.voiceMode == .live ? "Gemini Live" : "Classic")
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    settingsHint("Change CompanionVoiceMode in Info.plist to switch between live and classic.")
                }

                settingsGroup(title: "Shortcuts") {
                    settingsRow(label: "Talk to Dottie") {
                        ClickyHotkeyRecorderField(
                            hotkey: shortcutMonitor.talkHotkey,
                            onRecord: { shortcutMonitor.setTalkHotkey($0) },
                            onRecordingChanged: { shortcutMonitor.isSuspendedForRecording = $0 }
                        )
                    }
                    settingsRow(label: "Dictate") {
                        ClickyHotkeyRecorderField(
                            hotkey: shortcutMonitor.dictationHotkey,
                            onRecord: { shortcutMonitor.setDictationHotkey($0) },
                            onRecordingChanged: { shortcutMonitor.isSuspendedForRecording = $0 }
                        )
                    }
                    if shortcutMonitor.talkHotkey != .defaultTalk || shortcutMonitor.dictationHotkey != .defaultDictation {
                        settingsRow(label: "Back to ctrl + option and right option") {
                            Button("Reset") { shortcutMonitor.resetHotkeysToDefaults() }
                        }
                    }
                    settingsHint("Click a shortcut, then press the new one: modifier keys on their own (like right option or fn), or modifiers with a key (like cmd + shift + space). You hold it the same way to talk or dictate.")
                    settingsRow(label: "Circle things with the cursor while you talk") {
                        Toggle("", isOn: $isScreenAnnotationEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsHint("While you hold the talk shortcut, move the cursor around something to circle it. Dottie sees exactly what you marked.")
                    DottieEverydayShortcutRows(shortcuts: DottieEveryday.shared.shortcuts, shortcutMonitor: shortcutMonitor)
                }

                settingsGroup(title: "Everyday") {
                    DottieEverydaySettings(focus: DottieEveryday.shared.focus)
                }

                settingsGroup(title: "Appearance") {
                    settingsRow(label: "Show Dottie in the notch") {
                        Toggle("", isOn: Binding(
                            get: { companionManager.isNotchEnabled },
                            set: { companionManager.setNotchEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    settingsRow(label: "Keep the blue cursor visible") {
                        Toggle("", isOn: Binding(
                            get: { companionManager.isClickyCursorEnabled },
                            set: { companionManager.setClickyCursorEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    settingsHint("With the cursor off, it only appears while you're talking to Dottie.")
                    HomeCursorShapeSettings(cursorPet: companionManager.cursorPet)
                    settingsRow(label: "Notify me when a Dot finishes or needs me") {
                        Toggle("", isOn: $areDotNotificationsEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsHint("Shown while you're in another app. Click one to open that Dot; a request to use your Mac can be answered right from it.")
                }

                settingsGroup(title: "Dictation") {
                    settingsRow(label: "Hold \(shortcutMonitor.dictationHotkey.displayText) to dictate") {
                        Toggle("", isOn: $isDictationEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Words to spell your way")
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                        TextField("Names, product words, jargon (comma-separated)", text: $dictationCustomWords)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    settingsHint("Hold the shortcut, talk, and let go: Dottie types the cleaned-up text wherever your cursor is. If there's nowhere to type, it goes to your clipboard.")
                    settingsRow(label: "Show my words in the notch as I speak") {
                        Toggle("", isOn: $showsDictationLiveText)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsRow(label: "Detect the language automatically") {
                        Toggle("", isOn: $isDictationLanguageAutoDetected)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    if !isDictationLanguageAutoDetected {
                        settingsRow(label: "Language") {
                            Picker("", selection: $dictationLanguageCode) {
                                ForEach(DictationLanguageCatalog.languages) { language in
                                    Text(language.displayName).tag(language.code)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 180)
                        }
                    }
                    settingsHint("Auto-detect follows you across languages, even mid-sentence. Pin one language for the most accurate results.")
                    settingsRow(label: "Learn words I correct") {
                        Toggle("", isOn: $learnsDictationCorrections)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsHint("When you fix a name or word right after dictating, Dottie adds your spelling to your dictionary and uses it next time.")
                    if !dictationDictionary.learnedCorrections.isEmpty {
                        learnedWordsList
                    }
                }

                settingsGroup(title: "Using your Mac") {
                    settingsRow(label: "Computer-use driver") {
                        Text(isCuaDriverBundled ? "Built in" : (isCuaDriverInstalled ? "Installed" : "Missing"))
                            .foregroundColor(isCuaDriverInstalled ? DS.Colors.textSecondary : DS.Colors.warningText)
                    }
                    settingsRow(label: "Let Dots click and type without asking") {
                        Toggle("", isOn: $isComputerUseAlwaysAllowed)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    settingsHint(isCuaDriverInstalled
                        ? "Dots can always look at your apps. With this off, they ask in the notch before they click or type."
                        : "Dots operate apps through cua-driver, which the build normally puts inside Dottie. This build doesn't have it (it couldn't be downloaded while building). Rebuild with a network connection, or install it with: /bin/bash -c \"$(curl -fsSL https://cua.ai/driver/install.sh)\"")
                    settingsRow(label: "Tips Dottie learned from her jobs: \(learnedTipCount)") {
                        Button("Forget them") {
                            DottieScreenLessons.shared.forgetAll()
                            learnedTipCount = 0
                        }
                        .disabled(learnedTipCount == 0)
                    }
                    settingsHint("After each screen or TV job she keeps a tip for next time. Tips that keep working move to the top; ones that keep failing are dropped on their own.")
                }

                settingsGroup(title: "Connection") {
                    connectionSettings
                }

                settingsGroup(title: "History") {
                    settingsRow(label: "\(conversationStore.entries.count) saved exchanges") {
                        Button("Clear") { companionManager.forgetWholeConversation() }
                            .pointerCursor()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .onReceive(DottieHomeNavigator.shared.$requestedSettingsGroup) { requestedGroup in
            // Dottie opened a section herself: scroll to it once laid out.
            guard let requestedGroup else { return }
            DottieHomeNavigator.shared.requestedSettingsGroup = nil
            // A search could be hiding the section Dottie wants to show.
            settingsSearchText = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation { scrollProxy.scrollTo(requestedGroup, anchor: .top) }
            }
        }
        }
    }

    private var settingsSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
            TextField("Search settings", text: $settingsSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !settingsSearchText.isEmpty {
                Button {
                    settingsSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    /// Words for what each section holds, so searching "hotkey" or "update"
    /// finds the right section even when the word isn't in its title. Keyed
    /// by the section title passed to `settingsGroup`.
    private static let settingsSearchKeywordsByGroupTitle: [String: String] = [
        "Permissions": "accessibility screen recording microphone mic speech notifications allow access privacy",
        "Updates": "update version download new release check latest",
        "Helpers: Claude via MausBot": "claude mausbot helper anthropic model subscription bot",
        "Usage": "usage tokens cost gemini claude count speed",
        "Check everything": "check test diagnose self-check problems broken working",
        "Instant replays": "replay record recording clip video save",
        "Voice": "voice personality speak sound live classic mode tone talk",
        "Shortcuts": "shortcut hotkey keyboard key talk dictate circle annotate cursor ctrl option",
        "Everyday": "everyday focus shortcuts habits",
        "Appearance": "appearance notch cursor shape pet look show hide notifications dots",
        "Dictation": "dictation dictate type words spelling language dictionary corrections live text",
        "Using your Mac": "computer use mac driver cua click type allow tips lessons",
        "Connection": "connection server worker url secret network",
        "History": "history conversation clear forget saved exchanges",
    ]

    private func settingsGroupMatchesSearch(title: String) -> Bool {
        let searchWords = settingsSearchText
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !searchWords.isEmpty else { return true }
        let searchableGroupText = (title + " " + (Self.settingsSearchKeywordsByGroupTitle[title] ?? "")).lowercased()
        return searchWords.allSatisfy { searchableGroupText.contains($0) }
    }

    private var hasAnySettingsGroupMatchingSearch: Bool {
        Self.settingsSearchKeywordsByGroupTitle.keys.contains { settingsGroupMatchesSearch(title: $0) }
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        if settingsGroupMatchesSearch(title: title) {
            settingsGroupCard(title: title, content: content)
        }
    }

    private func settingsGroupCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        // Lets Dottie scroll straight to a section (DottieHomeNavigator).
        .id(title)
    }

    private func settingsRow<Accessory: View>(label: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            accessory()
                .font(.system(size: 12))
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSettings: some View {
        if let builtInWorkerBaseURL = ClickyWorkerConfiguration.builtInWorkerBaseURL, userWorkerBaseURL.isEmpty {
            settingsRow(label: "Server") {
                Text(builtInWorkerBaseURL)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            settingsHint("Built into this copy of Dottie. It holds the Gemini key, so the app never sees it.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Server address")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 8) {
                    TextField("https://dottie.yourname.workers.dev", text: $userWorkerBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button(isCheckingServer ? "Checking…" : "Check") { checkServer() }
                        .disabled(userWorkerBaseURL.isEmpty || isCheckingServer)
                        .pointerCursor()
                }
                SecureField("App secret (only if the server has one)", text: $userAppSharedSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            if let serverCheckMessage {
                Text(serverCheckMessage)
                    .font(.system(size: 11))
                    .foregroundColor(serverCheckMessage.hasPrefix("Connected") ? DS.Colors.textSecondary : DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            settingsHint("This copy of Dottie wasn't built with a server address. Paste the address of the Dottie server (whoever set up Dottie for you has it; INSTALL.md explains how to make one).")
        }
    }

    private func checkServer() {
        isCheckingServer = true
        serverCheckMessage = nil
        let addressToCheck = userWorkerBaseURL
        Task { @MainActor in
            let healthCheckResult = await ClickyWorkerConfiguration.checkHealth(ofBaseURL: addressToCheck)
            isCheckingServer = false
            switch healthCheckResult {
            case .ready:
                serverCheckMessage = "Connected. Dottie is ready to talk."
            case .missingGeminiKey:
                serverCheckMessage = "The server is up but has no Gemini key yet. Add GEMINI_API_KEY to it (see INSTALL.md)."
            case .unreachable(let reason):
                serverCheckMessage = "Couldn't reach it: \(reason)"
            }
        }
    }

    // MARK: - Learned words

    private var learnedWordsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dictationDictionary.learnedCorrections.count == 1
                     ? "1 learned word"
                     : "\(dictationDictionary.learnedCorrections.count) learned words")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
                Button("Clear all") { dictationDictionary.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(dictationDictionary.learnedCorrections) { learnedCorrection in
                    learnedWordChip(learnedCorrection)
                }
            }
        }
    }

    private func learnedWordChip(_ learnedCorrection: DictationLearnedCorrection) -> some View {
        HStack(spacing: 4) {
            Text(learnedCorrection.corrected)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: { dictationDictionary.remove(word: learnedCorrection.corrected) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove this word from your dictionary")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .help("Learned when you changed \u{201C}\(learnedCorrection.original)\u{201D} to \u{201C}\(learnedCorrection.corrected)\u{201D}")
    }

    private func settingsHint(_ hintText: String) -> some View {
        Text(hintText)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Voice

/// Settings → Voice: every voice with a play button, so the user can hear
/// each one before choosing. Picking a voice plays it too.
private struct HomeVoiceChooser: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var voicePreview = DottieVoicePreview.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dottie's voice")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(DottieVoicePreview.voices) { voice in
                    voiceTile(voice)
                }
            }
            if let problem = voicePreview.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { voicePreview.stop() }
    }

    private func voiceTile(_ voice: DottieVoicePreview.Voice) -> some View {
        let isSelected = companionManager.selectedVoiceName == voice.name
        return HStack(spacing: 8) {
            Button(action: {
                companionManager.setSelectedVoiceName(voice.name)
                voicePreview.play(voice.name)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(voice.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(voice.sound)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            previewButton(for: voice.name)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? DS.Colors.accentSubtle : DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? DS.Colors.textTertiary : DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func previewButton(for voiceName: String) -> some View {
        Button(action: { voicePreview.toggle(voiceName) }) {
            Group {
                if voicePreview.loadingVoiceName == voiceName {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: voicePreview.playingVoiceName == voiceName ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textPrimary)
                }
            }
            .frame(width: 24, height: 24)
            .background(Circle().fill(DS.Colors.surface3))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Hear \(voiceName)")
    }
}

// MARK: - Cursor shape

/// Settings → Appearance: the cursor's shape and whether it roams. Saying
/// "turn into a cat" to Dottie does the same, with any emoji.
private struct HomeCursorShapeSettings: View {
    @ObservedObject var cursorPet: DottieCursorPet

    var body: some View {
        HStack {
            Text("Cursor shape")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Menu(cursorPet.costume.map { costume in costume.emoji.map { "\($0) \(costume.name)" } ?? costume.name } ?? "Arrow") {
                Button("Arrow") { cursorPet.setCostume(nil) }
                Divider()
                ForEach(DottieCursorPet.library, id: \.name) { shape in
                    Button("\(shape.emoji)  \(shape.name)") {
                        cursorPet.setCostume(DottieCursorPet.Costume(
                            name: shape.name,
                            emoji: shape.emoji,
                            symbol: nil,
                            roams: DottieCursorPet.defaultRoaming(forName: shape.name)
                        ))
                    }
                }
            }
            .font(.system(size: 12))
            .frame(width: 160)
        }
        if cursorPet.costume != nil {
            HStack {
                Text("Walk around the screen on its own")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { cursorPet.costume?.roams == true },
                    set: { cursorPet.setRoaming($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
        Text("Or just tell Dottie \u{201C}turn into a cat\u{201D}: any emoji works. A roaming shape walks along your windows, jumps between them and hangs from the search bar, and comes back to the mouse when you talk to her.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Window

@MainActor
final class HomeWindowManager: NSObject, NSWindowDelegate {
    private let companionManager: CompanionManager
    private let conversationStore: ConversationStore
    private let clickyRoster: ClickyRoster
    private var homeWindow: NSWindow?

    init(companionManager: CompanionManager, conversationStore: ConversationStore, clickyRoster: ClickyRoster) {
        self.companionManager = companionManager
        self.conversationStore = conversationStore
        self.clickyRoster = clickyRoster
    }

    func showHomeWindow() {
        if homeWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Dottie"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            // Room for the labeled sidebar plus a readable page.
            window.minSize = NSSize(width: 720, height: 460)
            window.contentView = NSHostingView(rootView: HomeSpaceRootView(
                companionManager: companionManager,
                conversationStore: conversationStore,
                clickyRoster: clickyRoster
            ))
            window.center()
            window.delegate = self
            homeWindow = window
        }

        // Menu-bar-only apps must activate explicitly for a normal window to
        // come forward and take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        homeWindow?.makeKeyAndOrderFront(nil)
    }
}

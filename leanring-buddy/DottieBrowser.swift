//
//  DottieBrowser.swift
//  leanring-buddy
//
//  Real browser control through the browsers' own AppleScript: list and
//  switch tabs, open and close them, read the page the user is on, fill in
//  form fields and click buttons by their text. Works with Safari, Chrome,
//  Arc, Brave, Edge and Vivaldi. Reading and filling pages needs the
//  browser's "Allow JavaScript from Apple Events" switch, which Dottie can
//  turn on for Chrome-style browsers after asking.
//

import AppKit
import Foundation

@MainActor
enum DottieBrowser {
    private enum Dialect { case safari, chromium, arc }

    private struct Browser {
        let appName: String
        let dialect: Dialect
    }

    private static let knownBrowsers: [String: Browser] = [
        "com.apple.Safari": Browser(appName: "Safari", dialect: .safari),
        "com.google.Chrome": Browser(appName: "Google Chrome", dialect: .chromium),
        "com.brave.Browser": Browser(appName: "Brave Browser", dialect: .chromium),
        "com.microsoft.edgemac": Browser(appName: "Microsoft Edge", dialect: .chromium),
        "com.vivaldi.Vivaldi": Browser(appName: "Vivaldi", dialect: .chromium),
        "company.thebrowser.Browser": Browser(appName: "Arc", dialect: .arc)
    ]

    private struct BrowserTab {
        let windowIndex: Int
        let tabIndex: Int
        let isActive: Bool
        let title: String
        let url: String
    }

    /// The browser in front, else the default browser, else any open one.
    private static func currentBrowser() -> Browser? {
        let runningBundleIDs = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, let browser = knownBrowsers[frontmostID] {
            return browser
        }
        if let defaultBrowserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
           let defaultBrowserID = Bundle(url: defaultBrowserURL)?.bundleIdentifier,
           runningBundleIDs.contains(defaultBrowserID),
           let browser = knownBrowsers[defaultBrowserID] {
            return browser
        }
        return runningBundleIDs.lazy.compactMap { knownBrowsers[$0] }.first
    }

    // MARK: - Entry point

    static func perform(action: String, target: String?, value: String?) async -> String {
        guard let browser = currentBrowser() else {
            return "no supported browser is open (Safari, Chrome, Arc, Brave, Edge or Vivaldi). open_url opens a page in the default browser instead."
        }
        let trimmedTarget = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch action {
        case "list_tabs":
            return await listTabs(in: browser)
        case "read_page":
            return await runPageScript(Self.readPageJavaScript, in: browser)
        case "open_url":
            return await openURL(trimmedTarget, newTab: trimmedValue.lowercased() != "same tab", in: browser)
        case "switch_tab":
            return await switchTab(matching: trimmedTarget, in: browser)
        case "close_tab":
            return await closeTab(matching: trimmedTarget, in: browser)
        case "fill":
            return await fill(field: trimmedTarget, with: value ?? "", in: browser)
        case "click":
            return await click(text: trimmedTarget, in: browser)
        case "enable_page_access":
            return await enablePageAccess(in: browser)
        default:
            return "unknown browser action \(action)."
        }
    }

    // MARK: - Tabs

    private static func readTabs(in browser: Browser) async -> [BrowserTab]? {
        let titleProperty = browser.dialect == .safari ? "name" : "title"
        let activeIndexLine: String
        switch browser.dialect {
        case .safari: activeIndexLine = "set ai to index of current tab of w"
        case .chromium: activeIndexLine = "set ai to active tab index of w"
        case .arc: activeIndexLine = "set ai to 0"
        }
        let script = """
        tell application "\(browser.appName)"
            set out to ""
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                try
                    set ai to 0
                    try
                        \(activeIndexLine)
                    end try
                    set ti to 0
                    repeat with t in tabs of w
                        set ti to ti + 1
                        set isActive to "0"
                        if ti = ai then set isActive to "1"
                        set out to out & wi & tab & ti & tab & isActive & tab & (\(titleProperty) of t) & tab & (URL of t) & linefeed
                    end repeat
                end try
            end repeat
            return out
        end tell
        """
        let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 20)
        guard result.exitCode == 0 else { return nil }
        return result.output.split(separator: "\n").compactMap { line -> BrowserTab? in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let windowIndex = Int(fields[0]), let tabIndex = Int(fields[1]) else { return nil }
            return BrowserTab(windowIndex: windowIndex, tabIndex: tabIndex, isActive: fields[2] == "1", title: fields[3], url: fields[4])
        }
    }

    private static func listTabs(in browser: Browser) async -> String {
        guard let tabs = await readTabs(in: browser) else {
            return automationBlockedMessage(browser)
        }
        guard !tabs.isEmpty else { return "\(browser.appName) has no tabs open." }
        let lines = tabs.prefix(80).map { tab in
            "- \(tab.isActive ? "[showing] " : "")window \(tab.windowIndex), tab \(tab.tabIndex): \(DottieMacActions.shortened(tab.title, to: 80)) (\(DottieMacActions.shortened(tab.url, to: 80)))"
        }
        return "\(tabs.count) tabs in \(browser.appName):\n" + lines.joined(separator: "\n")
    }

    private static func findTab(matching text: String, in tabs: [BrowserTab]) -> BrowserTab? {
        let lowercasedText = text.lowercased()
        if lowercasedText.isEmpty || lowercasedText == "current" || lowercasedText == "this" {
            return tabs.first { $0.isActive && $0.windowIndex == 1 } ?? tabs.first { $0.windowIndex == 1 }
        }
        if let tabNumber = Int(lowercasedText) {
            return tabs.first { $0.windowIndex == 1 && $0.tabIndex == tabNumber }
        }
        return tabs.first { $0.title.lowercased() == lowercasedText }
            ?? tabs.first { $0.title.lowercased().contains(lowercasedText) || $0.url.lowercased().contains(lowercasedText) }
    }

    private static func switchTab(matching text: String, in browser: Browser) async -> String {
        guard let tabs = await readTabs(in: browser) else { return automationBlockedMessage(browser) }
        guard let tab = findTab(matching: text, in: tabs) else {
            return "no tab matches \(text). call list_tabs to see them."
        }
        let selectLine = browser.dialect == .safari
            ? "set current tab of window \(tab.windowIndex) to tab \(tab.tabIndex) of window \(tab.windowIndex)"
            : "set active tab index of window \(tab.windowIndex) to \(tab.tabIndex)"
        let script = """
        tell application "\(browser.appName)"
            activate
            \(selectLine)
            set index of window \(tab.windowIndex) to 1
        end tell
        """
        let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 15)
        return result.exitCode == 0 ? "switched to \(tab.title)." : "couldn't switch tabs: \(DottieMacActions.shortened(result.errorOutput, to: 200))"
    }

    private static func closeTab(matching text: String, in browser: Browser) async -> String {
        guard let tabs = await readTabs(in: browser) else { return automationBlockedMessage(browser) }
        guard let tab = findTab(matching: text, in: tabs) else {
            return "no tab matches \(text). call list_tabs to see them."
        }
        let script = "tell application \"\(browser.appName)\" to close tab \(tab.tabIndex) of window \(tab.windowIndex)"
        let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 15)
        return result.exitCode == 0 ? "closed \(tab.title)." : "couldn't close it: \(DottieMacActions.shortened(result.errorOutput, to: 200))"
    }

    private static func openURL(_ urlText: String, newTab: Bool, in browser: Browser) async -> String {
        var normalizedURLText = urlText
        if !normalizedURLText.contains("://") {
            normalizedURLText = "https://" + normalizedURLText
        }
        guard URL(string: normalizedURLText) != nil, !urlText.isEmpty else { return "that isn't a web address." }
        let quotedURL = appleScriptString(normalizedURLText)
        let body: String
        switch (browser.dialect, newTab) {
        case (.safari, true):
            body = """
            if (count of windows) = 0 then
                make new document with properties {URL:\(quotedURL)}
            else
                tell front window to set current tab to (make new tab with properties {URL:\(quotedURL)})
            end if
            """
        case (.safari, false):
            body = "set URL of current tab of front window to \(quotedURL)"
        case (_, true):
            body = """
            if (count of windows) = 0 then make new window
            tell front window to make new tab with properties {URL:\(quotedURL)}
            """
        case (_, false):
            body = "set URL of active tab of front window to \(quotedURL)"
        }
        let script = "tell application \"\(browser.appName)\"\nactivate\n\(body)\nend tell"
        let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 15)
        if result.exitCode != 0, let pageURL = URL(string: normalizedURLText) {
            NSWorkspace.shared.open(pageURL)
        }
        return "opened \(normalizedURLText)."
    }

    // MARK: - Page access

    private static func fill(field: String, with value: String, in browser: Browser) async -> String {
        guard !field.isEmpty else { return "say which field to fill." }
        let arguments = jsonLiteral([field, value])
        let outcome = await runPageScript("(\(Self.fillJavaScript)).apply(null, \(arguments))", in: browser)
        switch outcome {
        case "NOTFOUND": return "couldn't find a field like \(field). read_page lists the form fields."
        case "PASSWORD": return "that's a password field; Dottie never types passwords. ask the user to type it."
        case "NOOPTION": return "that dropdown has no option like \(value)."
        default: return outcome.hasPrefix("OK") ? "filled in \(outcome.dropFirst(3))." : outcome
        }
    }

    private static let riskyClickWords = [
        "buy", "pay", "purchase", "order", "checkout", "check out", "send", "submit", "delete", "remove",
        "post", "publish", "confirm", "transfer", "subscribe", "book", "sign up", "unsubscribe", "cancel"
    ]

    private static func click(text: String, in browser: Browser) async -> String {
        guard !text.isEmpty else { return "say what to click." }
        let lowercasedText = text.lowercased()
        if riskyClickWords.contains(where: { lowercasedText.contains($0) }) {
            let isAllowed = DottieConfirmation.ask(
                title: "Let Dottie click \u{201C}\(text)\u{201D}?",
                detail: "This could send, buy, post or delete something in \(browser.appName).",
                confirmButtonTitle: "Click it"
            )
            guard isAllowed else { return "the user said no, so it wasn't clicked." }
        }
        let outcome = await runPageScript("(\(Self.clickJavaScript))(\(jsonLiteral([text]).dropFirst().dropLast()))", in: browser)
        if outcome == "NOTFOUND" {
            return "couldn't find anything to click called \(text) on the page. read_page lists the buttons; for things outside the page use click_on_screen."
        }
        return outcome.hasPrefix("OK") ? "clicked \(outcome.dropFirst(3))." : outcome
    }

    private static func runPageScript(_ javaScript: String, in browser: Browser) async -> String {
        let quotedJavaScript = appleScriptString(javaScript)
        let script: String
        switch browser.dialect {
        case .safari:
            script = "tell application \"Safari\" to do JavaScript \(quotedJavaScript) in current tab of front window"
        case .chromium:
            script = "tell application \"\(browser.appName)\" to execute active tab of front window javascript \(quotedJavaScript)"
        case .arc:
            script = "tell application \"Arc\" to tell front window to tell active tab to execute javascript \(quotedJavaScript)"
        }
        let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 30)
        guard result.exitCode == 0 else {
            let errorText = result.errorOutput
            if errorText.localizedCaseInsensitiveContains("javascript") {
                return "\(browser.appName) doesn't let Dottie read pages yet. call browser with action enable_page_access (it asks the user first), or tell the user: \(enableInstructions(for: browser))"
            }
            if errorText.contains("-1743") || errorText.localizedCaseInsensitiveContains("not authorized") {
                return automationBlockedMessage(browser)
            }
            return "couldn't reach the page: \(DottieMacActions.shortened(errorText, to: 200))"
        }
        return result.output
    }

    private static func enableInstructions(for browser: Browser) -> String {
        switch browser.dialect {
        case .safari:
            return "in Safari, Settings → Advanced → turn on Show features for web developers, then Develop menu → Allow JavaScript from Apple Events."
        case .chromium, .arc:
            return "in \(browser.appName), View menu → Developer → Allow JavaScript from Apple Events."
        }
    }

    /// Flips the browser's own menu switch, after the user says yes.
    private static func enablePageAccess(in browser: Browser) async -> String {
        guard browser.dialect != .arc else { return "tell the user: \(enableInstructions(for: browser))" }
        let isAllowed = DottieConfirmation.ask(
            title: "Let Dottie read and fill pages in \(browser.appName)?",
            detail: "Dottie will turn on \(browser.appName)'s \u{201C}Allow JavaScript from Apple Events\u{201D} setting, so she can read the page you're on and fill in forms when you ask. You can turn it off in the same menu.",
            confirmButtonTitle: "Turn it on"
        )
        guard isAllowed else { return "the user said no." }
        let menuPath = browser.dialect == .safari
            ? "click menu item \"Allow JavaScript from Apple Events\" of menu 1 of menu bar item \"Develop\" of menu bar 1"
            : "click menu item \"Allow JavaScript from Apple Events\" of menu 1 of menu item \"Developer\" of menu 1 of menu bar item \"View\" of menu bar 1"
        let script = """
        tell application "\(browser.appName)" to activate
        delay 0.3
        tell application "System Events" to tell process "\(browser.appName)"
            \(menuPath)
        end tell
        """
        let result = await DottieMacActions.runProcess("/usr/bin/osascript", arguments: ["-e", script], timeout: 15)
        guard result.exitCode == 0 else {
            return "couldn't flip it automatically. tell the user: \(enableInstructions(for: browser))"
        }
        return "turned on page access in \(browser.appName). \(browser.dialect == .safari ? "Safari may ask the user to confirm." : "")"
    }

    private static func automationBlockedMessage(_ browser: Browser) -> String {
        "macOS hasn't let Dottie control \(browser.appName) yet. the user needs to click OK on the macOS prompt, or turn on Dottie → \(browser.appName) in System Settings → Privacy & Security → Automation."
    }

    // MARK: - Helpers

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A JSON array is also a valid JavaScript literal.
    private static func jsonLiteral(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let sharedJavaScriptHelpers = """
    function vis(e){var r=e.getBoundingClientRect();return r.width>0&&r.height>0;}
    function lab(e){if(e.id){var l=document.querySelector('label[for="'+CSS.escape(e.id)+'"]');if(l)return l.innerText.trim();}var p=e.closest('label');if(p&&p.innerText.trim())return p.innerText.trim();return (e.getAttribute('aria-label')||e.placeholder||e.name||e.id||'').trim();}
    """

    private static let readPageJavaScript = """
    (function(){\(sharedJavaScriptHelpers)
    var fields=[].slice.call(document.querySelectorAll('input,textarea,select,[contenteditable="true"]')).filter(function(e){return vis(e)&&e.type!=='hidden';}).slice(0,40).map(function(e){var kind=e.tagName==='INPUT'?(e.type||'text'):e.tagName.toLowerCase();var v=(e.value&&e.type!=='password')?' = '+String(e.value).slice(0,40):'';return '- '+(lab(e)||'(unnamed)').slice(0,60)+' ['+kind+']'+v;});
    var buttons=[].slice.call(document.querySelectorAll('button,[role=button],input[type=submit],input[type=button]')).filter(vis).map(function(e){return (e.innerText||e.value||e.getAttribute('aria-label')||'').trim();}).filter(Boolean).slice(0,40);
    var text=(document.body?document.body.innerText:'').replace(/\\n{3,}/g,'\\n\\n');
    return 'title: '+document.title+'\\nurl: '+location.href+'\\n\\nform fields:\\n'+(fields.join('\\n')||'none')+'\\n\\nbuttons: '+(buttons.join(' | ')||'none')+'\\n\\npage text:\\n'+text.slice(0,12000);
    })()
    """

    private static let fillJavaScript = """
    function(field,value){\(sharedJavaScriptHelpers)
    var want=field.toLowerCase().trim();
    var els=[].slice.call(document.querySelectorAll('input,textarea,select,[contenteditable="true"]')).filter(function(e){return vis(e)&&e.type!=='hidden';});
    var el=els.find(function(e){return lab(e).toLowerCase()===want;})||els.find(function(e){return lab(e).toLowerCase().indexOf(want)>=0;})||els.find(function(e){return (e.name||'').toLowerCase().indexOf(want)>=0;});
    if(!el)return 'NOTFOUND';
    if(el.type==='password')return 'PASSWORD';
    el.focus();
    if(el.isContentEditable){el.innerText=value;}
    else if(el.tagName==='SELECT'){var o=[].slice.call(el.options).find(function(o){return o.text.toLowerCase().indexOf(value.toLowerCase())>=0||o.value===value;});if(!o)return 'NOOPTION';el.value=o.value;}
    else if(el.type==='checkbox'||el.type==='radio'){var on=/^(true|yes|on|1|checked)$/i.test(value);if(el.checked!==on)el.click();}
    else{var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;Object.getOwnPropertyDescriptor(proto,'value').set.call(el,value);}
    el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));
    return 'OK '+(lab(el)||'the field');
    }
    """

    private static let clickJavaScript = """
    function(want){\(sharedJavaScriptHelpers)
    want=want.toLowerCase().trim();
    var els=[].slice.call(document.querySelectorAll('a,button,[role=button],[role=link],[role=tab],[role=menuitem],[role=option],input[type=submit],input[type=button],summary')).filter(vis);
    function name(e){return (e.innerText||e.value||e.getAttribute('aria-label')||e.title||'').trim().toLowerCase();}
    var el=els.find(function(e){return name(e)===want;})||els.find(function(e){return name(e).indexOf(want)>=0;});
    if(!el)return 'NOTFOUND';
    el.scrollIntoView({block:'center'});el.click();
    return 'OK '+name(el).slice(0,60);
    }
    """
}

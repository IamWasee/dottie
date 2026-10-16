//
//  DottieScreenAction.swift
//  leanring-buddy
//
//  Things voice Dottie can do on the screen herself when the user asks:
//  click, type, press keys, scroll, open a page, and draw on the screen.
//  Shipped Clicky leaves acting to its background agents; here the voice
//  companion can also do quick, single steps directly, so "click sign in",
//  "go back" or "circle the error" happen right away. Jobs with several
//  steps go to DottieScreenTaskRunner (do_task_on_screen).
//
//  The tools are declared for Gemini Live here, and DottieScreenActionPerformer
//  carries them out with synthetic events (which need the Accessibility
//  permission the app already has for its shortcuts). CompanionManager
//  resolves where on screen each one goes, flying Dottie's cursor there first
//  so the user sees what's about to happen.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum DottieScreenAction {
    enum ScrollDirection: String {
        case up, down, left, right
    }

    enum DrawingShape: String, CaseIterable {
        case circle, box, underline, arrow
    }

    /// x and y are 0-1000 across the turn's screen frame, like point_at_element.
    case click(normalizedX: Double, normalizedY: Double, label: String?, clickCount: Int, isRightClick: Bool)
    case typeText(text: String, pressEnterAfter: Bool)
    case pressKeys(keyCombination: String)
    case scroll(direction: ScrollDirection, amount: Int)
    case openURL(URL)
    case draw(shape: DrawingShape, normalizedX: Double, normalizedY: Double, normalizedSize: Double?, label: String?, note: String?)
    case clearDrawings

    // MARK: - Tool declarations

    static let functionNames: Set<String> = [
        "click_on_screen", "type_text", "press_keys", "scroll_screen", "open_url", "draw_on_screen", "clear_drawings"
    ]

    private static let onlyWhenAskedNote = " Only use this when the user explicitly asks you to do it for them in this turn; never on your own initiative."

    static var functionDeclarations: [[String: Any]] {
        [clickOnScreenDeclaration, typeTextDeclaration, pressKeysDeclaration, scrollScreenDeclaration, openUrlDeclaration, drawOnScreenDeclaration, clearDrawingsDeclaration]
    }

    private static var clickOnScreenDeclaration: [String: Any] {
        [
            "name": "click_on_screen",
            "description": "Click something on the user's screen for them, like a button, link, tab or menu item in the most recent screen frame. Your cursor flies there first, then clicks." + onlyWhenAskedNote,
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "x": ["type": "INTEGER", "description": "Horizontal position of the element's center, 0 (left edge of the frame) to 1000 (right edge)."],
                    "y": ["type": "INTEGER", "description": "Vertical position of the element's center, 0 (top edge of the frame) to 1000 (bottom edge)."],
                    "label": ["type": "STRING", "description": "The element's visible text or name exactly as on screen (like 'Sign in'), else a 1-3 word name."],
                    "double_click": ["type": "BOOLEAN", "description": "True to double-click."],
                    "right_click": ["type": "BOOLEAN", "description": "True to right-click."]
                ],
                "required": ["x", "y", "label"]
            ]
        ]
    }

    private static var typeTextDeclaration: [String: Any] {
        [
            "name": "type_text",
            "description": "Type text into whatever field is focused on the user's screen (click the field first if it isn't focused). Never types into password boxes." + onlyWhenAskedNote,
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "text": ["type": "STRING", "description": "Exactly the text to type."],
                    "press_enter": ["type": "BOOLEAN", "description": "True to press Return afterwards, e.g. to search or send."]
                ],
                "required": ["text"]
            ]
        ]
    }

    private static var pressKeysDeclaration: [String: Any] {
        [
            "name": "press_keys",
            "description": "Press a key or keyboard shortcut on the user's Mac, like 'cmd+t' for a new tab, 'cmd+[' to go back a page, 'cmd+]' to go forward, 'cmd+l' to focus the address bar, 'enter', 'escape', 'tab', or 'cmd+w'." + onlyWhenAskedNote,
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "keys": ["type": "STRING", "description": "Modifiers and one key joined by '+': cmd, shift, option, ctrl, plus a letter, digit, symbol, or a name like enter, escape, tab, space, delete, up, down, left, right, pageup, pagedown, home, end, f1-f12."]
                ],
                "required": ["keys"]
            ]
        ]
    }

    private static var scrollScreenDeclaration: [String: Any] {
        [
            "name": "scroll_screen",
            "description": "Scroll the window under the user's mouse." + onlyWhenAskedNote,
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "direction": ["type": "STRING", "enum": ["up", "down", "left", "right"], "description": "Which way the content should move into view: down shows what's below."],
                    "amount": ["type": "INTEGER", "description": "How far, 1 (a little) to 10 (a lot). 3 is about half a screen."]
                ],
                "required": ["direction"]
            ]
        ]
    }

    private static var openUrlDeclaration: [String: Any] {
        [
            "name": "open_url",
            "description": "Open a web page in the user's default browser." + onlyWhenAskedNote,
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "url": ["type": "STRING", "description": "The full address, starting with https://."]
                ],
                "required": ["url"]
            ]
        ]
    }

    private static var drawOnScreenDeclaration: [String: Any] {
        [
            "name": "draw_on_screen",
            "description": "Draw on top of the user's screen to show them something: a circle or box around it, an arrow pointing at it, or an underline below it, with an optional short note. It fades away after a few seconds." + onlyWhenAskedNote,
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "shape": ["type": "STRING", "enum": DrawingShape.allCases.map(\.rawValue), "description": "What to draw."],
                    "x": ["type": "INTEGER", "description": "Horizontal center of the thing, 0-1000 across the frame."],
                    "y": ["type": "INTEGER", "description": "Vertical center of the thing, 0-1000 down the frame."],
                    "size": ["type": "INTEGER", "description": "Rough width of the thing, 0-1000 across the frame. Leave out for something button-sized."],
                    "label": ["type": "STRING", "description": "The thing's visible text or name, used to find it exactly."],
                    "note": ["type": "STRING", "description": "Optional few-word note written next to the drawing."]
                ],
                "required": ["shape", "x", "y"]
            ]
        ]
    }

    private static var clearDrawingsDeclaration: [String: Any] {
        [
            "name": "clear_drawings",
            "description": "Erase everything you drew on the screen.",
            "parameters": ["type": "OBJECT", "properties": [String: Any]()]
        ]
    }

    init?(functionName: String, arguments: [String: Any]) {
        func number(_ key: String) -> Double? { (arguments[key] as? NSNumber)?.doubleValue }
        func text(_ key: String) -> String? {
            let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func flag(_ key: String) -> Bool { (arguments[key] as? Bool) ?? ((arguments[key] as? NSNumber)?.boolValue ?? false) }

        switch functionName {
        case "click_on_screen":
            guard let x = number("x"), let y = number("y") else { return nil }
            self = .click(normalizedX: x, normalizedY: y, label: text("label"),
                          clickCount: flag("double_click") ? 2 : 1, isRightClick: flag("right_click"))
        case "type_text":
            guard let typedText = arguments["text"] as? String, !typedText.isEmpty else { return nil }
            self = .typeText(text: typedText, pressEnterAfter: flag("press_enter"))
        case "press_keys":
            guard let keys = text("keys") else { return nil }
            self = .pressKeys(keyCombination: keys)
        case "scroll_screen":
            guard let direction = text("direction").flatMap({ ScrollDirection(rawValue: $0.lowercased()) }) else { return nil }
            self = .scroll(direction: direction, amount: Int(number("amount") ?? 3))
        case "open_url":
            guard var address = text("url") else { return nil }
            if !address.contains("://") { address = "https://" + address }
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            self = .openURL(url)
        case "draw_on_screen":
            guard let shape = text("shape").flatMap({ DrawingShape(rawValue: $0.lowercased()) }),
                  let x = number("x"), let y = number("y") else { return nil }
            self = .draw(shape: shape, normalizedX: x, normalizedY: y, normalizedSize: number("size"),
                         label: text("label"), note: text("note"))
        case "clear_drawings":
            self = .clearDrawings
        default:
            return nil
        }
    }
}

// MARK: - Performing actions

/// Synthetic mouse and keyboard events. Points are global AppKit
/// coordinates (bottom-left origin), like the rest of the app.
@MainActor
enum DottieScreenActionPerformer {
    static var canPostEvents: Bool { AXIsProcessTrusted() }

    static func click(at appKitPoint: CGPoint, clickCount: Int, isRightClick: Bool) {
        let originalMouseLocation = quartzPoint(fromAppKit: NSEvent.mouseLocation)
        let clickLocation = quartzPoint(fromAppKit: appKitPoint)
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let (downType, upType): (CGEventType, CGEventType) = isRightClick ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        let mouseButton: CGMouseButton = isRightClick ? .right : .left

        CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: clickLocation, mouseButton: mouseButton)?
            .post(tap: .cghidEventTap)
        for clickNumber in 1...max(1, clickCount) {
            let mouseDown = CGEvent(mouseEventSource: eventSource, mouseType: downType, mouseCursorPosition: clickLocation, mouseButton: mouseButton)
            let mouseUp = CGEvent(mouseEventSource: eventSource, mouseType: upType, mouseCursorPosition: clickLocation, mouseButton: mouseButton)
            mouseDown?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
            mouseUp?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
            mouseDown?.post(tap: .cghidEventTap)
            mouseUp?.post(tap: .cghidEventTap)
        }

        // Put the user's pointer back where it was, a beat after the click
        // lands, so Dottie doesn't steal their mouse.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CGWarpMouseCursorPosition(originalMouseLocation)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    /// True when the focused field is a password box (or secure input is on).
    static var isFocusedFieldSecure: Bool {
        if IsSecureEventInputEnabled() { return true }
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else { return false }
        let focusedElement = focusedElementValue as! AXUIElement
        for attributeName in [kAXRoleAttribute, kAXSubroleAttribute] {
            var attributeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedElement, attributeName as CFString, &attributeValue) == .success,
               (attributeValue as? String) == "AXSecureTextField" {
                return true
            }
        }
        return false
    }

    /// Types with Unicode keyboard events, a few characters at a time, which
    /// works in native, web and Electron fields without touching the clipboard.
    static func type(_ text: String) async {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let utf16Units = Array(text.utf16)
        var startIndex = 0
        while startIndex < utf16Units.count {
            let endIndex = min(startIndex + 16, utf16Units.count)
            var chunk = Array(utf16Units[startIndex..<endIndex])
            for isKeyDown in [true, false] {
                let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: isKeyDown)
                keyEvent?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                keyEvent?.post(tap: .cghidEventTap)
            }
            startIndex = endIndex
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    /// Presses a combination like "cmd+shift+t". Returns false when the key
    /// name isn't known.
    @discardableResult
    static func press(keyCombination: String) -> Bool {
        let parts = keyCombination.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        // "cmd++" means the plus key.
        var keyName = parts.last ?? ""
        if keyName.isEmpty && parts.count >= 2 { keyName = "=" }

        var flags: CGEventFlags = []
        for modifierName in parts.dropLast() where !modifierName.isEmpty {
            switch modifierName {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "option", "opt", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return false
            }
        }
        guard let keyCode = virtualKeyCode(forKeyName: keyName) else { return false }

        let eventSource = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        return true
    }

    /// Scrolls whatever is under the pointer, or under `appKitPoint` when
    /// given (the pointer goes back where it was afterwards).
    static func scroll(direction: DottieScreenAction.ScrollDirection, amount: Int, at appKitPoint: CGPoint? = nil) {
        let clampedAmount = max(1, min(amount, 10))
        let linesPerStep: Int32 = 4
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let originalMouseLocation = quartzPoint(fromAppKit: NSEvent.mouseLocation)
        if let appKitPoint {
            CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: quartzPoint(fromAppKit: appKitPoint), mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        defer {
            if appKitPoint != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    CGWarpMouseCursorPosition(originalMouseLocation)
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
            }
        }
        for _ in 0..<clampedAmount {
            let verticalLines: Int32
            let horizontalLines: Int32
            switch direction {
            case .down: (verticalLines, horizontalLines) = (-linesPerStep, 0)
            case .up: (verticalLines, horizontalLines) = (linesPerStep, 0)
            case .right: (verticalLines, horizontalLines) = (0, -linesPerStep)
            case .left: (verticalLines, horizontalLines) = (0, linesPerStep)
            }
            let scrollEvent = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 2,
                                      wheel1: verticalLines, wheel2: horizontalLines, wheel3: 0)
            if let appKitPoint {
                scrollEvent?.location = quartzPoint(fromAppKit: appKitPoint)
            }
            scrollEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Quartz events use a top-left origin on the primary display.
    private static func quartzPoint(fromAppKit appKitPoint: CGPoint) -> CGPoint {
        let primaryDisplayHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: appKitPoint.x, y: primaryDisplayHeight - appKitPoint.y)
    }

    private static func virtualKeyCode(forKeyName keyName: String) -> CGKeyCode? {
        let namedKeys: [String: Int] = [
            "enter": kVK_Return, "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
            "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "home": kVK_Home, "end": kVK_End,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave
        ]
        return namedKeys[keyName].map { CGKeyCode($0) }
    }
}

//
//  DottieAccessibilityCast.swift
//  leanring-buddy
//
//  Turns a value an app handed back through Accessibility into the type
//  Dottie expected, or nil when the app handed back something else. Swift
//  can't check these Core Foundation types with "as?", so every caller
//  used to force the cast, and an app answering with the wrong kind of
//  value would have crashed Dottie. The check lives here once.
//

import ApplicationServices

nonisolated enum DottieAccessibilityCast {

    /// The value as an Accessibility element (a window, a button, a text
    /// field), or nil when it is missing or something else.
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // The type was checked on the line above, so this cast can't fail.
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    /// The value as an Accessibility value (a position, a size, a text
    /// range), or nil when it is missing or something else.
    static func axValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // The type was checked on the line above, so this cast can't fail.
        // swiftlint:disable:next force_cast
        return (value as! AXValue)
    }
}

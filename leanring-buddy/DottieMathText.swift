//
//  DottieMathText.swift
//  leanring-buddy
//
//  Turns typed math and science into what you'd write by hand: x^2 → x²,
//  sqrt(x) → √(x), \theta → θ, >= → ≥, H2O → H₂O. Everything Dottie writes
//  on the board, the screen and in notes goes through it.
//

import AppKit
import Foundation
import Vision

/// Turns typed math and science into what you'd write by hand: x^2 → x²,
/// 3*4 → 3×4, sqrt(x) → √(x), \theta → θ, >= → ≥, x_1 → x₁, \frac{a}{b} → a/b,
/// H2O → H₂O, SO4^2- → SO₄²⁻, Na+ → Na⁺, <=> → ⇌, 25 degC → 25 °C.
/// Color and bold markings (DottieInkText) are kept.
enum DottieMathText {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "t": "ᵗ", "T": "ᵀ", "o": "ᵒ"
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "x": "ₓ", "n": "ₙ", "i": "ᵢ",
        "o": "ₒ", "k": "ₖ", "m": "ₘ", "t": "ₜ", "r": "ᵣ", "s": "ₛ", "p": "ₚ", "j": "ⱼ", "h": "ₕ", "l": "ₗ"
    ]
    /// Longer names first wherever one starts another (\leftarrow before
    /// \left, \neq before \ne, <=> before <=).
    private static let words: [(String, String)] = [
        // Arrows (chemistry's ⇌ among them).
        ("\\rightleftharpoons", "⇌"), ("\\leftrightarrow", "↔"), ("\\Leftrightarrow", "⇔"), ("\\iff", "⇔"),
        ("\\Rightarrow", "⇒"), ("\\implies", "⇒"), ("\\Leftarrow", "⇐"), ("\\rightarrow", "→"), ("\\leftarrow", "←"),
        ("\\uparrow", "↑"), ("\\downarrow", "↓"), ("\\to", "→"), ("\\gets", "←"),
        ("\\left", ""), ("\\right", ""), ("\\text", ""), ("\\mathrm", ""), ("\\displaystyle", ""),
        ("\\mathbb{R}", "ℝ"), ("\\mathbb{N}", "ℕ"), ("\\mathbb{Z}", "ℤ"), ("\\mathbb{Q}", "ℚ"), ("\\mathbb{C}", "ℂ"),
        // Greek, capitals where they differ from Latin letters.
        ("\\varepsilon", "ε"), ("\\epsilon", "ε"), ("\\varphi", "φ"), ("\\vartheta", "ϑ"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\Gamma", "Γ"), ("\\delta", "δ"), ("\\Delta", "Δ"),
        ("\\zeta", "ζ"), ("\\eta", "η"), ("\\theta", "θ"), ("\\Theta", "Θ"), ("\\iota", "ι"), ("\\kappa", "κ"),
        ("\\lambda", "λ"), ("\\Lambda", "Λ"), ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"), ("\\Xi", "Ξ"),
        ("\\pi", "π"), ("\\Pi", "Π"), ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\Sigma", "Σ"), ("\\tau", "τ"),
        ("\\upsilon", "υ"), ("\\phi", "φ"), ("\\Phi", "Φ"), ("\\chi", "χ"), ("\\psi", "ψ"), ("\\Psi", "Ψ"),
        ("\\omega", "ω"), ("\\Omega", "Ω"), ("\\hbar", "ℏ"), ("\\ell", "ℓ"),
        // Calculus, sums and sets.
        ("\\sum", "∑"), ("\\prod", "∏"), ("\\iiint", "∭"), ("\\iint", "∬"), ("\\oint", "∮"), ("\\int", "∫"),
        ("\\partial", "∂"), ("\\nabla", "∇"), ("\\infty", "∞"), ("\\lim", "lim"),
        ("\\notin", "∉"), ("\\in", "∈"), ("\\subseteq", "⊆"), ("\\subset", "⊂"), ("\\supset", "⊃"),
        ("\\cup", "∪"), ("\\cap", "∩"), ("\\emptyset", "∅"), ("\\varnothing", "∅"), ("\\forall", "∀"), ("\\exists", "∃"),
        ("\\neg", "¬"), ("\\land", "∧"), ("\\lor", "∨"),
        // Comparisons and operators.
        ("\\neq", "≠"), ("\\ne", "≠"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\le", "≤"), ("\\ge", "≥"),
        ("\\ll", "≪"), ("\\gg", "≫"), ("\\approx", "≈"), ("\\equiv", "≡"), ("\\cong", "≅"), ("\\simeq", "≃"),
        ("\\sim", "∼"), ("\\propto", "∝"), ("\\times", "×"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"),
        ("\\cdots", "⋯"), ("\\ldots", "…"), ("\\dots", "…"), ("\\cdot", "·"),
        // Geometry.
        ("\\angle", "∠"), ("\\perp", "⊥"), ("\\parallel", "∥"), ("\\triangle", "△"), ("\\square", "□"),
        ("\\degree", "°"), ("^\\circ", "°"), ("\\circ", "°"), ("\\therefore", "∴"), ("\\because", "∵"),
        // Roots.
        ("\\sqrt[3]", "∛"), ("\\sqrt[4]", "∜"), ("\\sqrt", "√"), ("cbrt", "∛"), ("sqrt", "√"),
        // Typed the plain way.
        ("<=>", "⇌"), ("<->", "↔"), ("<-", "←"), ("=>", "⇒"), ("->", "→"),
        ("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("=/=", "≠"), ("~=", "≈"), ("+/-", "±"), ("+-", "±"),
        ("*", "×"), ("$", "")
    ]

    /// Patterns that need the letters around them: pi on its own, degrees
    /// and units after a number, a minus sign, simple fractions.
    private static let patternReplacements: [(NSRegularExpression, String)] = ([
        (#"\bpi\b"#, "π"),
        (#"\binfinity\b"#, "∞"),
        (#"(\d)\s?deg\s?C\b"#, "$1 °C"),
        (#"(\d)\s?deg\s?F\b"#, "$1 °F"),
        (#"(\d)\s?(deg|degrees)\b"#, "$1°"),
        (#"(\d)\s?ohms?\b"#, "$1 Ω"),
        (#"(\d)\s?micro(m|g|s|L)\b"#, "$1 µ$2"),
        // A minus sign, not a hyphen: spaced, or before a number or bracket
        // at the start or after = ( and operators.
        (#" - "#, " − "),
        (#"(^|[=(\[,×÷+/≤≥<>]\s?)-(?=[\d(a-zA-Zπθ√])"#, "$1−"),
        (#"(?<![\d./])1/2(?![\d/])"#, "½"), (#"(?<![\d./])1/3(?![\d/])"#, "⅓"), (#"(?<![\d./])2/3(?![\d/])"#, "⅔"),
        (#"(?<![\d./])1/4(?![\d/])"#, "¼"), (#"(?<![\d./])3/4(?![\d/])"#, "¾"), (#"(?<![\d./])1/8(?![\d/])"#, "⅛")
    ] as [(String, String)]).compactMap { pattern, replacement in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
    }

    /// Every element's symbol, so H2O, CO2 and Ca(OH)2 get subscripts but
    /// MP3, A1 or Q3 don't.
    private static let elementSymbols: Set<String> = Set("""
    H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr Rb Sr Y Zr Nb Mo \
    Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg Tl \
    Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og
    """.split(separator: " ").map(String.init))

    /// Pretty math and science, keeping any color or bold markings.
    static func pretty(_ text: String) -> String {
        DottieInkText.transformingText(in: text, using: prettyPlain)
    }

    /// Whether a line is code (or a command) rather than math or words, so
    /// it's written exactly: making it pretty turned from_pretrained into
    /// fromₚretrained and **inputs into × ×inputs.
    static func looksLikeCode(_ text: String) -> Bool {
        let codePatterns = [
            #"(?m)^\s*(from\s+[\w.]+\s+import\s|import\s+[\w.]+(\s+as\s+\w+)?\s*$|def\s+\w+\(|class\s+\w+\s*[(:{]|print\(|const\s+\w+\s*=|function\s+\w+\(|#include|pip3?\s+install|npm\s+(install|run|i)\b|git\s+(clone|commit|push|pull|add|checkout)\b|\$\s)"#,
            #"\b[A-Za-z_]\w*\.[A-Za-z_]\w*\("#,
            #"\b[a-z]{2,}_[a-z]{2,}\w*\s*[(=]"#,
            #";\s*$"#,
            #"==="#
        ]
        return codePatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// The code and commands in an answer, so Home can show each with a
    /// Copy button: fenced ``` blocks, and `inline` spans that look like
    /// code. Duplicates are left out.
    static func codeSnippets(in answerText: String) -> [String] {
        var snippets: [String] = []
        func add(_ candidate: String) {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCandidate.isEmpty, !snippets.contains(trimmedCandidate) { snippets.append(trimmedCandidate) }
        }
        var textWithoutFences = answerText
        if let fencePattern = try? NSRegularExpression(pattern: "```[a-zA-Z0-9_+-]*\\n?([\\s\\S]*?)```") {
            let range = NSRange(answerText.startIndex..., in: answerText)
            for match in fencePattern.matches(in: answerText, range: range) {
                if let codeRange = Range(match.range(at: 1), in: answerText) { add(String(answerText[codeRange])) }
            }
            textWithoutFences = fencePattern.stringByReplacingMatches(in: answerText, range: range, withTemplate: " ")
        }
        if let inlinePattern = try? NSRegularExpression(pattern: "`([^`\\n]{3,300})`") {
            let range = NSRange(textWithoutFences.startIndex..., in: textWithoutFences)
            for match in inlinePattern.matches(in: textWithoutFences, range: range) {
                guard let codeRange = Range(match.range(at: 1), in: textWithoutFences) else { continue }
                let inlineCode = String(textWithoutFences[codeRange])
                if looksLikeCode(inlineCode) { add(inlineCode) }
            }
        }
        return snippets
    }

    /// Pretty, with the markings taken out, for what the cursor says.
    static func prettyPlainText(_ text: String) -> String {
        DottieInkText.plainText(pretty(text))
    }

    private static func prettyPlain(_ text: String) -> String {
        var result = text
        result = replaceFractions(in: result)
        for (word, symbol) in words {
            result = result.replacingOccurrences(of: word, with: symbol)
        }
        for (pattern, replacement) in patternReplacements {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        result = chemicalFormulas(in: result)
        result = replaceScripts(in: result, marker: "^", map: superscripts)
        result = replaceScripts(in: result, marker: "_", map: subscripts)
        return result.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }

    /// H2O → H₂O, C6H12O6 → C₆H₁₂O₆, Ca(OH)2 → Ca(OH)₂, Na+ → Na⁺, Cl- → Cl⁻,
    /// Fe3+ → Fe³⁺. Only words made wholly of element symbols, numbers and
    /// brackets change, so ordinary words and labels are left alone.
    private static func chemicalFormulas(in text: String) -> String {
        guard let formulaPattern = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])((?:[A-Z][a-z]?|\(|\)|\[|\]|\d)+)([+−-]?)(?![A-Za-z0-9])"#) else { return text }
        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        for match in formulaPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let body = nsText.substring(with: match.range(at: 1))
            let charge = nsText.substring(with: match.range(at: 2))
            guard let rewritten = rewrittenFormula(body: body, charge: charge) else { continue }
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            result += rewritten
            lastEnd = match.range.location + match.range.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    private static func rewrittenFormula(body: String, charge: String) -> String? {
        // Split into element symbols, brackets and digit runs.
        var parts: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character.isUppercase {
                var symbol = String(character)
                let nextIndex = body.index(after: index)
                if nextIndex < body.endIndex, body[nextIndex].isLowercase {
                    symbol.append(body[nextIndex])
                    index = body.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                parts.append(symbol)
            } else if character.isNumber {
                var digits = ""
                while index < body.endIndex, body[index].isNumber {
                    digits.append(body[index])
                    index = body.index(after: index)
                }
                parts.append(digits)
            } else {
                parts.append(String(character))
                index = body.index(after: index)
            }
        }
        let elementParts = parts.filter { $0.first?.isUppercase == true }
        guard !elementParts.isEmpty, elementParts.allSatisfy(elementSymbols.contains) else { return nil }
        // A number after the first part counts atoms (a leading one, as in
        // 2H2O, is how many molecules).
        let hasCount = parts.dropFirst().contains { $0.first?.isNumber == true }
        let isIon = !charge.isEmpty
        guard hasCount || isIon else { return nil }
        // A lone symbol with a sign ("C-", "I+") reads as text, not an ion,
        // unless it's a common ion.
        if !hasCount, isIon, elementParts.count == 1, !["Na", "K", "Cl", "H", "Li", "Ag", "F", "Br"].contains(elementParts[0]) { return nil }

        var rewritten = ""
        for (partIndex, part) in parts.enumerated() {
            guard part.first?.isNumber == true else {
                rewritten += part
                continue
            }
            let isLastPart = partIndex == parts.count - 1
            if isLastPart && isIon {
                // Fe3+ → Fe³⁺: the number before a charge is the charge's.
                rewritten += String(part.compactMap { superscripts[$0] })
            } else if partIndex == 0 {
                // A leading number is how many: 2H2O.
                rewritten += part
            } else {
                rewritten += String(part.compactMap { subscripts[$0] })
            }
        }
        if isIon { rewritten += charge == "+" ? "⁺" : "⁻" }
        return rewritten
    }

    /// \frac{a}{b} → a/b (with brackets when a part has more than one term).
    private static func replaceFractions(in text: String) -> String {
        var result = text
        while let fracRange = result.range(of: "\\frac{") {
            guard let numerator = bracedGroup(in: result, from: result.index(before: fracRange.upperBound)),
                  result.index(after: numerator.end) < result.endIndex,
                  result[result.index(after: numerator.end)] == "{",
                  let denominator = bracedGroup(in: result, from: result.index(after: numerator.end)) else { break }
            func wrap(_ part: String) -> String {
                part.contains(where: { "+- ".contains($0) }) ? "(\(part))" : part
            }
            result.replaceSubrange(fracRange.lowerBound...denominator.end, with: "\(wrap(numerator.content))/\(wrap(denominator.content))")
        }
        return result
    }

    /// The text inside the braces that open at `openIndex`.
    private static func bracedGroup(in text: String, from openIndex: String.Index) -> (content: String, end: String.Index)? {
        guard text[openIndex] == "{" else { return nil }
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return (String(text[text.index(after: openIndex)..<index]), index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// x^2, x^{10}, x^(n+1): raised (or lowered) when every character has a
    /// small form, otherwise left as typed.
    private static func replaceScripts(in text: String, marker: Character, map: [Character: Character]) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == marker, text.index(after: index) < text.endIndex else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            var contentStart = text.index(after: index)
            var contentEnd = contentStart
            let opener = text[contentStart]
            if opener == "{" || opener == "(" {
                // To the matching bracket, so x^(3 - (-3)) takes the whole
                // power, not just up to the first ")".
                let closer: Character = opener == "{" ? "}" : ")"
                contentStart = text.index(after: contentStart)
                contentEnd = contentStart
                var depth = 1
                while contentEnd < text.endIndex {
                    if text[contentEnd] == opener { depth += 1 }
                    if text[contentEnd] == closer {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    contentEnd = text.index(after: contentEnd)
                }
            } else {
                // A run of digits (maybe signed, like ^-1), or one letter.
                if opener == "-" || opener == "+" {
                    contentEnd = text.index(after: contentEnd)
                }
                if contentEnd < text.endIndex && text[contentEnd].isNumber {
                    while contentEnd < text.endIndex && text[contentEnd].isNumber { contentEnd = text.index(after: contentEnd) }
                    // An ion's charge: SO4^2- → SO₄²⁻.
                    if contentEnd < text.endIndex, "+-−".contains(text[contentEnd]) {
                        let afterSign = text.index(after: contentEnd)
                        if afterSign == text.endIndex || !(text[afterSign].isLetter || text[afterSign].isNumber) {
                            contentEnd = afterSign
                        }
                    }
                } else if contentEnd == contentStart {
                    contentEnd = text.index(after: contentEnd)
                }
            }
            // Spaces inside a power don't count: x^(3 + 3) → x³⁺³.
            let content = text[contentStart..<contentEnd].filter { $0 != " " }
            let mapped = content.compactMap { map[$0] }
            if !content.isEmpty, mapped.count == content.count {
                output.append(String(mapped))
                index = (opener == "{" || opener == "(") && contentEnd < text.endIndex ? text.index(after: contentEnd) : contentEnd
            } else {
                output.append(character)
                index = text.index(after: index)
            }
        }
        return output
    }
}

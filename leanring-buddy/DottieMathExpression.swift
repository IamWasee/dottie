//
//  DottieMathExpression.swift
//  leanring-buddy
//
//  A function of x typed the usual way (2x^2 - 3x + 1, sin(x)/x, |x|),
//  read and evaluated exactly, so the curve Dottie plots is the real one.
//

import AppKit
import Foundation
import Vision

/// A function of x typed the usual way, for plot: 2x^2 - 3x + 1,
/// sin(x)/x, sqrt(x+4), |x|, e^(-x^2), 3(x-1)^2. Evaluated exactly, so the
/// curve Dottie draws is the real one.
struct DottieMathExpression {
    private indirect enum Node {
        case number(Double)
        case variable
        case unary(String, Node)
        case binary(Character, Node, Node)
        case function(String, Node)
    }

    private let root: Node

    init?(_ text: String) {
        var source = text.lowercased()
        if let equalsIndex = source.firstIndex(of: "=") {
            source = String(source[source.index(after: equalsIndex)...])
        }
        source = source
            .replacingOccurrences(of: "²", with: "^2").replacingOccurrences(of: "³", with: "^3")
            .replacingOccurrences(of: "√", with: "sqrt").replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "·", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
        var parser = Parser(tokens: Parser.tokenize(source))
        guard let root = parser.parseExpression(), parser.isAtEnd else { return nil }
        self.root = root
    }

    func evaluate(x: Double) -> Double {
        Self.evaluate(root, x: x)
    }

    private static func evaluate(_ node: Node, x: Double) -> Double {
        switch node {
        case .number(let value): return value
        case .variable: return x
        case .unary(_, let operand): return -evaluate(operand, x: x)
        case .binary(let operation, let left, let right):
            let leftValue = evaluate(left, x: x), rightValue = evaluate(right, x: x)
            switch operation {
            case "+": return leftValue + rightValue
            case "-": return leftValue - rightValue
            case "*": return leftValue * rightValue
            case "/": return leftValue / rightValue
            default: return pow(leftValue, rightValue)
            }
        case .function(let name, let argument):
            let value = evaluate(argument, x: x)
            switch name {
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "tan": return tan(value)
            case "asin", "arcsin": return asin(value)
            case "acos", "arccos": return acos(value)
            case "atan", "arctan": return atan(value)
            case "sqrt": return sqrt(value)
            case "abs": return abs(value)
            case "ln": return log(value)
            case "log": return log10(value)
            case "exp": return exp(value)
            default: return .nan
            }
        }
    }

    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case symbol(Character)
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var isAtEnd: Bool { position >= tokens.count }

        static let functionNames: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "arcsin", "arccos", "arctan", "sqrt", "abs", "ln", "log", "exp"]

        static func tokenize(_ source: String) -> [Token] {
            var tokens: [Token] = []
            var index = source.startIndex
            while index < source.endIndex {
                let character = source[index]
                if character.isWhitespace {
                    index = source.index(after: index)
                } else if character.isNumber || character == "." {
                    var end = index
                    while end < source.endIndex && (source[end].isNumber || source[end] == ".") { end = source.index(after: end) }
                    tokens.append(.number(Double(source[index..<end]) ?? .nan))
                    index = end
                } else if character.isLetter {
                    var end = index
                    while end < source.endIndex && source[end].isLetter { end = source.index(after: end) }
                    // Split runs like "xsin" or "2pix" into known names and single letters.
                    var word = Substring(source[index..<end])
                    while !word.isEmpty {
                        if let known = (functionNames.sorted { $0.count > $1.count } + ["pi"]).first(where: { word.hasPrefix($0) }) {
                            tokens.append(.name(known))
                            word = word.dropFirst(known.count)
                        } else {
                            tokens.append(.name(String(word.first!)))
                            word = word.dropFirst()
                        }
                    }
                    index = end
                } else if character == "|" {
                    tokens.append(.symbol("|"))
                    index = source.index(after: index)
                } else {
                    tokens.append(.symbol(character))
                    index = source.index(after: index)
                }
            }
            return tokens
        }

        private func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        mutating func parseExpression() -> Node? {
            guard var left = parseTerm() else { return nil }
            while case .symbol(let operation)? = peek(), operation == "+" || operation == "-" {
                position += 1
                guard let right = parseTerm() else { return nil }
                left = .binary(operation, left, right)
            }
            return left
        }

        /// Products, including implied ones: 2x, 3(x+1), x sin(x).
        private mutating func parseTerm() -> Node? {
            guard var left = parseUnary() else { return nil }
            while let token = peek() {
                if case .symbol(let operation) = token, operation == "*" || operation == "/" {
                    position += 1
                    guard let right = parseUnary() else { return nil }
                    left = .binary(operation, left, right)
                } else if startsFactor(token) {
                    guard let right = parsePower() else { return nil }
                    left = .binary("*", left, right)
                } else {
                    break
                }
            }
            return left
        }

        private func startsFactor(_ token: Token) -> Bool {
            switch token {
            case .number, .name: return true
            case .symbol(let character): return character == "("
            }
        }

        private mutating func parseUnary() -> Node? {
            if case .symbol(let sign)? = peek(), sign == "-" || sign == "+" {
                position += 1
                guard let operand = parseUnary() else { return nil }
                return sign == "-" ? .unary("-", operand) : operand
            }
            return parsePower()
        }

        private mutating func parsePower() -> Node? {
            guard let base = parseAtom() else { return nil }
            if case .symbol("^")? = peek() {
                position += 1
                guard let exponent = parseUnary() else { return nil }
                return .binary("^", base, exponent)
            }
            return base
        }

        private mutating func parseAtom() -> Node? {
            guard let token = peek() else { return nil }
            position += 1
            switch token {
            case .number(let value):
                return value.isNaN ? nil : .number(value)
            case .name(let name):
                if name == "x" { return .variable }
                if name == "pi" { return .number(.pi) }
                if name == "e" { return .number(M_E) }
                guard Self.functionNames.contains(name) else { return nil }
                // sin(x), or sin x
                guard let argument = parsePower() else { return nil }
                return .function(name, argument)
            case .symbol("("):
                guard let inner = parseExpression(), case .symbol(")")? = peek() else { return nil }
                position += 1
                return inner
            case .symbol("|"):
                guard let inner = parseExpression(), case .symbol("|")? = peek() else { return nil }
                position += 1
                return .function("abs", inner)
            default:
                return nil
            }
        }
    }
}

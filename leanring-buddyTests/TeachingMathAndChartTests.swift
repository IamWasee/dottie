//
//  TeachingMathAndChartTests.swift
//  leanring-buddyTests
//
//  Unit tests for the numbers behind Dottie's teaching: the function of x
//  she plots (DottieMathExpression) and the chart data she reads from what
//  the user said or circled (DottieChartData). A mistake here draws a curve
//  or a bar that looks right and is wrong.
//

import Foundation
import Testing
@testable import Dottie

/// True when the two numbers are the same apart from floating point dust.
private func isClose(_ actualValue: Double?, _ expectedValue: Double) -> Bool {
    guard let actualValue else { return false }
    return abs(actualValue - expectedValue) < 1e-9
}

@MainActor
struct MathExpressionTests {

    @Test func polynomialWithImpliedMultiplication() {
        #expect(isClose(DottieMathExpression("2x^2 - 3x + 1")?.evaluate(x: 2), 3))
    }

    @Test func everythingUpToTheEqualsSignIsIgnored() {
        #expect(isClose(DottieMathExpression("y = x + 1")?.evaluate(x: 2), 3))
    }

    @Test func numberInFrontOfBracketsMultiplies() {
        #expect(isClose(DottieMathExpression("3(x-1)^2")?.evaluate(x: 3), 12))
    }

    @Test func barsMeanAbsoluteValue() {
        #expect(isClose(DottieMathExpression("|x|")?.evaluate(x: -4), 4))
    }

    @Test func minusInFrontAppliesAfterThePower() {
        #expect(isClose(DottieMathExpression("-x^2")?.evaluate(x: 3), -9))
    }

    @Test func negativeExponent() {
        #expect(isClose(DottieMathExpression("2^-1")?.evaluate(x: 0), 0.5))
    }

    @Test func functionsWithAndWithoutBrackets() {
        #expect(isClose(DottieMathExpression("sin x")?.evaluate(x: 0), 0))
        #expect(isClose(DottieMathExpression("sqrt(x+4)")?.evaluate(x: 5), 3))
        #expect(isClose(DottieMathExpression("log(x)")?.evaluate(x: 100), 2))
        #expect(isClose(DottieMathExpression("ln(e)")?.evaluate(x: 0), 1))
    }

    @Test func eAndPiAreTheConstants() {
        #expect(isClose(DottieMathExpression("e^(-x^2)")?.evaluate(x: 0), 1))
        #expect(isClose(DottieMathExpression("2pix")?.evaluate(x: 1), 2 * Double.pi))
    }

    @Test func handwrittenSymbolsAreUnderstood() {
        #expect(isClose(DottieMathExpression("x²")?.evaluate(x: 3), 9))
        #expect(isClose(DottieMathExpression("√x")?.evaluate(x: 9), 3))
        #expect(isClose(DottieMathExpression("6 ÷ x")?.evaluate(x: 3), 2))
        #expect(isClose(DottieMathExpression("2 × x − 1")?.evaluate(x: 4), 7))
    }

    @Test func capitalLettersReadTheSame() {
        #expect(isClose(DottieMathExpression("COS(X)")?.evaluate(x: 0), 1))
    }

    @Test func textThatIsNotAFunctionOfXIsRefused() {
        #expect(DottieMathExpression("") == nil)
        #expect(DottieMathExpression("2 +") == nil)
        #expect(DottieMathExpression("(x") == nil)
        #expect(DottieMathExpression("x)") == nil)
        #expect(DottieMathExpression("2 $ 3") == nil)
        #expect(DottieMathExpression("hello") == nil)
    }
}

@MainActor
struct ChartDataParsingTests {

    @Test func labelsWithValues() {
        let chartPoints = DottieChartData.parse("Mon: 12; Tue: 9")

        #expect(chartPoints.count == 2)
        #expect(chartPoints.first?.label == "Mon")
        #expect(chartPoints.first?.x == nil)
        #expect(chartPoints.first?.value == 12)
        #expect(chartPoints.last?.label == "Tue")
        #expect(chartPoints.last?.value == 9)
    }

    @Test func pairsOfNumbersArePositions() {
        let chartPoints = DottieChartData.parse("1, 3; 2, 5")

        #expect(chartPoints.count == 2)
        #expect(chartPoints.first?.label == nil)
        #expect(chartPoints.first?.x == 1)
        #expect(chartPoints.first?.value == 3)
        #expect(chartPoints.last?.x == 2)
        #expect(chartPoints.last?.value == 5)
    }

    @Test func numberLabelBecomesThePositionAndThousandsCommasAreDropped() {
        let chartPoints = DottieChartData.parse("2020: 1,200")

        #expect(chartPoints.count == 1)
        #expect(chartPoints.first?.label == nil)
        #expect(chartPoints.first?.x == 2020)
        #expect(chartPoints.first?.value == 1200)
    }

    @Test func labelAndValueWithNothingBetweenThem() {
        let chartPoints = DottieChartData.parse("Jan 1,200")

        #expect(chartPoints.count == 1)
        #expect(chartPoints.first?.label == "Jan")
        #expect(chartPoints.first?.value == 1200)
    }

    @Test func linesAndEqualsSignsWorkLikeSemicolonsAndColons() {
        let chartPoints = DottieChartData.parse("A = 5\nB = 7")

        #expect(chartPoints.map(\.label) == ["A", "B"])
        #expect(chartPoints.map(\.value) == [5, 7])
    }

    @Test func negativeAndDecimalValues() {
        #expect(DottieChartData.parse("Loss: -4.5").first?.value == -4.5)
    }

    @Test func entriesWithoutANumberAreLeftOut() {
        let chartPoints = DottieChartData.parse("Mon: none; hello; Tue: 9")

        #expect(chartPoints.count == 1)
        #expect(chartPoints.first?.label == "Tue")
    }
}

@MainActor
struct ChartScaleAndLabelTests {

    @Test func barScaleStartsAtZeroWithRoundSteps() {
        let valueScale = DottieChartData.valueScale(values: [12, 9], startsAtZero: true, givenRange: nil)

        #expect(valueScale.minimum == 0)
        #expect(valueScale.maximum == 12.5)
        #expect(valueScale.ticks == [0, 2.5, 5, 7.5, 10, 12.5])
    }

    @Test func equalValuesStillGetARange() {
        let valueScale = DottieChartData.valueScale(values: [5, 5], startsAtZero: false, givenRange: nil)

        #expect(isClose(valueScale.minimum, 4))
        #expect(isClose(valueScale.maximum, 6))
        #expect(valueScale.ticks.count == 5)
    }

    @Test func givenRangeIsKeptAsIs() {
        let valueScale = DottieChartData.valueScale(values: [], startsAtZero: false, givenRange: (0, 100))

        #expect(valueScale.minimum == 0)
        #expect(valueScale.maximum == 100)
        #expect(valueScale.ticks == [0, 20, 40, 60, 80, 100])
    }

    @Test func shortNumbers() {
        #expect(DottieChartData.shortNumber(12) == "12")
        #expect(DottieChartData.shortNumber(2.5) == "2.5")
        #expect(DottieChartData.shortNumber(2.46) == "2.5")
        #expect(DottieChartData.shortNumber(0) == "0")
        #expect(DottieChartData.shortNumber(-3) == "-3")
        #expect(DottieChartData.shortNumber(0.25) == "0.25")
        #expect(DottieChartData.shortNumber(1_200) == "1200")
        #expect(DottieChartData.shortNumber(12_000) == "12k")
        #expect(DottieChartData.shortNumber(12_500) == "12.5k")
        #expect(DottieChartData.shortNumber(3_000_000) == "3M")
    }
}

@MainActor
struct ChartTableRowTests {

    @Test func headerRowIsLeftOutAndMoneySignsAreDropped() {
        let chartText = DottieChartData.chartText(fromRows: ["Month | Sales", "Jan | $1,200", "Feb | 950"])

        #expect(chartText == "Jan: 1200; Feb: 950")
    }

    @Test func loneNumberIsJustAValue() {
        #expect(DottieChartData.chartText(fromRows: ["42"]) == "42")
    }

    @Test func rowOfTwoNumbersUsesTheFirstAsTheLabel() {
        #expect(DottieChartData.chartText(fromRows: ["2020 | 15"]) == "2020: 15")
    }

    @Test func tableRowsReadBackAsChartPoints() {
        let chartText = DottieChartData.chartText(fromRows: ["Month | Sales", "Jan | $1,200", "Feb | 950"])
        let chartPoints = DottieChartData.parse(chartText)

        #expect(chartPoints.map(\.label) == ["Jan", "Feb"])
        #expect(chartPoints.map(\.value) == [1200, 950])
    }
}

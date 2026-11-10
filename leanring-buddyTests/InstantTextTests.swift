//
//  InstantTextTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieInstantText: how spoken or typed words are cleaned
//  up before the instant lane decides whether the Mac can do them with no
//  AI. A mistake here makes "open Safari" miss, or the wrong thing match.
//

import Testing
@testable import Dottie

struct InstantTextNormalizingTests {

    @Test func greetingPolitenessAndPunctuationAreDropped() {
        #expect(DottieInstantText.normalized("Hey Dottie, can you open Safari please?") == "open safari")
    }

    @Test func plainCommandOnlyLosesItsCapitalLetters() {
        #expect(DottieInstantText.normalized("Open Safari") == "open safari")
    }

    @Test func dotsInsideAWebAddressStayButTheSentenceDotGoes() {
        #expect(DottieInstantText.normalized("Open github.com.") == "open github.com")
    }

    @Test func extraSpacesCollapseToOne() {
        #expect(DottieInstantText.normalized("  volume    up  ") == "volume up")
    }

    @Test func curlyApostropheBecomesAStraightOne() {
        #expect(DottieInstantText.normalized("What’s playing") == "what's playing")
    }

    @Test func textThatIsOnlyFillerBecomesEmpty() {
        #expect(DottieInstantText.normalized("") == "")
        #expect(DottieInstantText.normalized("?!") == "")
    }
}

struct InstantTextSplittingTests {

    @Test func oneCommandStaysOnePart() {
        #expect(DottieInstantText.splitIntoParts("open safari") == ["open safari"])
    }

    @Test func andSplitsTwoCommands() {
        #expect(DottieInstantText.splitIntoParts("close slack and open notes") == ["close slack", "open notes"])
    }

    @Test func andThenCountsAsOneJoiningPhrase() {
        #expect(DottieInstantText.splitIntoParts("open safari and then play music") == ["open safari", "play music"])
    }

    @Test func threeCommandsBecomeThreeParts() {
        #expect(DottieInstantText.splitIntoParts("open notes then open mail also quit slack") == ["open notes", "open mail", "quit slack"])
    }

    @Test func emptyTextHasNoParts() {
        #expect(DottieInstantText.splitIntoParts("").isEmpty)
    }
}

struct InstantTextWordHelpersTests {

    @Test func leadingArticleAndTrailingAppAreDropped() {
        #expect(DottieInstantText.withoutArticles("the notes app") == "notes")
        #expect(DottieInstantText.withoutArticles("my music") == "music")
        #expect(DottieInstantText.withoutArticles("safari") == "safari")
    }

    @Test func articleInsideANameIsKept() {
        #expect(DottieInstantText.withoutArticles("find my") == "find my")
    }

    @Test func wordsThatDependOnTheMomentAreNoticed() {
        #expect(DottieInstantText.containsMomentWord("close this"))
        #expect(DottieInstantText.containsMomentWord("open that file"))
        #expect(!DottieInstantText.containsMomentWord("open safari"))
    }

    @Test func momentWordInsideALongerWordDoesNotCount() {
        // "italic" and "thermostat" contain "it" and "her".
        #expect(!DottieInstantText.containsMomentWord("make italic thermostat"))
    }

    @Test func sameWordsInAnyOrderGiveTheSameKey() {
        #expect(DottieInstantText.sortedWordsKey("open safari now") == "now open safari")
        #expect(DottieInstantText.sortedWordsKey("safari open now") == DottieInstantText.sortedWordsKey("now open safari"))
    }
}

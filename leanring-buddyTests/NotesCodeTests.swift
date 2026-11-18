//
//  NotesCodeTests.swift
//  leanring-buddyTests
//
//  Unit tests for telling code apart from math and words, so the notes
//  board writes code exactly instead of turning from_pretrained into
//  fromₚretrained and **inputs into × ×inputs.
//

import Testing
@testable import Dottie

struct NotesCodeTests {
    @Test func codeIsRecognized() {
        #expect(DottieMathText.looksLikeCode("from transformers import AutoTokenizer"))
        #expect(DottieMathText.looksLikeCode("tokenizer = AutoTokenizer.from_pretrained(\"microsoft/phi-4\")"))
        #expect(DottieMathText.looksLikeCode("output = model.generate(**inputs, max_new_tokens=50)"))
        #expect(DottieMathText.looksLikeCode("print(tokenizer.decode(output[0], skip_special_tokens=True))"))
        #expect(DottieMathText.looksLikeCode("pip install transformers"))
        #expect(DottieMathText.looksLikeCode("const total = items.length;"))
    }

    @Test func mathAndWordsAreNot() {
        #expect(DottieMathText.looksLikeCode("a^2 + b^2 = c^2") == false)
        #expect(DottieMathText.looksLikeCode("x_1 = 3 * 4") == false)
        #expect(DottieMathText.looksLikeCode("v_max = 9.8 m/s^2") == false)
        #expect(DottieMathText.looksLikeCode("H2O + CO2 -> H2CO3") == false)
        #expect(DottieMathText.looksLikeCode("Import duties raise prices for buyers.") == false)
        #expect(DottieMathText.looksLikeCode("the answer is {highlight:x = 4}") == false)
        #expect(DottieMathText.looksLikeCode("f(x) = sin(x)/x") == false)
    }
}

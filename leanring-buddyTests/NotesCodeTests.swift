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

@MainActor
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

    @Test func everyKindOfCodeLineIsRecognized() {
        let codeLines = [
            "def train(model):", "class Dog:", "npm run dev", "npm i react", "pip3 install torch",
            "git clone https://github.com/x/y", "$ ls -la", "#include <stdio.h>", "import numpy as np",
            "if (a === b) return", "let x = 5;", "function add(a, b) {", "print('hi')",
            "df = pd.read_csv('data.csv')", "learning_rate = 0.01"
        ]
        for codeLine in codeLines {
            #expect(DottieMathText.looksLikeCode(codeLine), "\(codeLine) should be code")
        }
    }

    @Test func sentencesAndFormulasThatLookCloseAreNotCode() {
        let notCode = [
            "The class was fun.", "print the page", "Use git to save work.", "e = mc^2",
            "Sales grew 5% in Q3.", "Install Python from the website.",
            "The function of the heart is to pump blood.", "speed = distance / time",
            "P(A and B) = P(A) × P(B)", "x = (-b ± √(b² - 4ac)) / 2a", ""
        ]
        for line in notCode {
            #expect(DottieMathText.looksLikeCode(line) == false, "\(line) should not be code")
        }
    }

    @Test func fencedCodeIsFoundWithOrWithoutALanguage() {
        let answer = "Run this:\n```bash\npip install transformers\n```\nthen\n```\nprint('done')\n```"
        #expect(DottieMathText.codeSnippets(in: answer) == ["pip install transformers", "print('done')"])
    }

    @Test func inlineCodeIsFoundOnlyWhenItIsCode() {
        let answer = "Type `npm run dev` in the folder, then open `the page` you like."
        #expect(DottieMathText.codeSnippets(in: answer) == ["npm run dev"])
    }

    @Test func theSameSnippetIsOfferedOnce() {
        let answer = "```\nnpm run dev\n```\nAgain: `npm run dev`"
        #expect(DottieMathText.codeSnippets(in: answer) == ["npm run dev"])
    }

    @Test func answersWithoutCodeOfferNothing() {
        #expect(DottieMathText.codeSnippets(in: "").isEmpty)
        #expect(DottieMathText.codeSnippets(in: "The answer is 42.").isEmpty)
        #expect(DottieMathText.codeSnippets(in: "An empty fence ```\n```").isEmpty)
        // Too short to be a command.
        #expect(DottieMathText.codeSnippets(in: "press `a`").isEmpty)
    }
}

@MainActor
struct NotesBlockWritingTests {
    @Test func aParagraphHoldingCodeBecomesACodeBlockWrittenExactly() {
        let written = DottieNotesTools.writtenBlock(kind: .paragraph, rawText: "model = AutoModel.from_pretrained(name)")
        #expect(written.kind == .code)
        #expect(written.text == "model = AutoModel.from_pretrained(name)")
    }

    @Test func bulletsNumberedAndEquationsHoldingCodeBecomeCode() {
        for kind in [DottieNoteBlock.Kind.bullet, .numbered, .equation] {
            #expect(DottieNotesTools.writtenBlock(kind: kind, rawText: "pip install torch").kind == .code)
        }
    }

    @Test func mathStaysMathAndIsMadePretty() {
        let written = DottieNotesTools.writtenBlock(kind: .equation, rawText: "x^2 + y^2 = r^2")
        #expect(written.kind == .equation)
        #expect(written.text.contains("²"))
    }

    @Test func aCodeBlockIsNeverMadePretty() {
        let written = DottieNotesTools.writtenBlock(kind: .code, rawText: "a**2 + b_c")
        #expect(written.kind == .code)
        #expect(written.text == "a**2 + b_c")
    }

    @Test func headingsKeepTheirKindEvenWithCodeWords() {
        #expect(DottieNotesTools.writtenBlock(kind: .heading, rawText: "pip install torch").kind == .heading)
        #expect(DottieNotesTools.writtenBlock(kind: .subheading, rawText: "import numpy as np").kind == .subheading)
    }

    @Test func aRepeatedBatchHasTheSameSignatureAndADifferentOneDoesNot() {
        func block(_ kind: DottieNoteBlock.Kind, _ text: String) -> DottieNoteBlock {
            DottieNoteBlock(kind: kind, text: text, ink: .white, indentLevel: 0, number: nil, picture: nil)
        }
        let first = DottieNotesTools.batchSignature(of: [block(.heading, "Setup"), block(.code, "pip install torch")])
        let repeated = DottieNotesTools.batchSignature(of: [block(.heading, "Setup"), block(.code, "pip install torch")])
        let changed = DottieNotesTools.batchSignature(of: [block(.heading, "Setup"), block(.code, "pip install numpy")])
        let sameTextOtherKind = DottieNotesTools.batchSignature(of: [block(.heading, "Setup"), block(.paragraph, "pip install torch")])
        #expect(first == repeated)
        #expect(first != changed)
        #expect(first != sameTextOtherKind)
        #expect(DottieNotesTools.batchSignature(of: []).isEmpty)
    }
}

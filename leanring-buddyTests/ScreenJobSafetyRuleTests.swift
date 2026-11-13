//
//  ScreenJobSafetyRuleTests.swift
//  leanring-buddyTests
//
//  Unit tests for the rules a screen job checks on the Mac, whatever the
//  model thinks: which buttons pay, send, post or delete (asked about first
//  while the user is away), which details may never be saved for filling in
//  forms (passwords, card and ID numbers), and whether a request is one
//  quick action or a goal that one click doesn't finish. A mistake here
//  pays for something unasked, or keeps a secret on disk.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct AwayModeRiskyButtonTests {

    @Test func buttonsThatPaySendPostOrDeleteAreRisky() {
        #expect(DottieAwayMode.isRiskyLabel("Send"))
        #expect(DottieAwayMode.isRiskyLabel("Pay now"))
        #expect(DottieAwayMode.isRiskyLabel("Place order"))
        #expect(DottieAwayMode.isRiskyLabel("Check out"))
        #expect(DottieAwayMode.isRiskyLabel("Submit"))
        #expect(DottieAwayMode.isRiskyLabel("Delete account"))
        #expect(DottieAwayMode.isRiskyLabel("Empty Trash"))
        #expect(DottieAwayMode.isRiskyLabel("Unsubscribe"))
    }

    @Test func capitalLettersAndSymbolsAroundTheWordDoNotHideIt() {
        #expect(DottieAwayMode.isRiskyLabel("SEND"))
        #expect(DottieAwayMode.isRiskyLabel("Send message…"))
        #expect(DottieAwayMode.isRiskyLabel("Buy 2 for $5"))
        #expect(DottieAwayMode.isRiskyLabel("(Publish)"))
    }

    @Test func everydayButtonsAreNotRisky() {
        #expect(!DottieAwayMode.isRiskyLabel("Next"))
        #expect(!DottieAwayMode.isRiskyLabel("Cancel"))
        #expect(!DottieAwayMode.isRiskyLabel("Sign in"))
        #expect(!DottieAwayMode.isRiskyLabel("Search"))
        #expect(!DottieAwayMode.isRiskyLabel(""))
    }

    @Test func aRiskyWordInsideALongerWordDoesNotCount() {
        #expect(!DottieAwayMode.isRiskyLabel("Sender"))
        #expect(!DottieAwayMode.isRiskyLabel("Repost settings"))
        #expect(!DottieAwayMode.isRiskyLabel("Payment details"))
        #expect(!DottieAwayMode.isRiskyLabel("Removed items"))
        #expect(!DottieAwayMode.isRiskyLabel("Transferring"))
    }
}

@MainActor
struct FormDetailsNeverSavedTests {

    @Test func everydayDetailsAreSaved() {
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "email", value: "sam@example.com"))
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "full_name", value: "Sam Example"))
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "company", value: "Acme"))
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "date_of_birth", value: "1990-04-12"))
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "postcode", value: "90210"))
    }

    @Test func secretFieldsAreRefusedByName() {
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "password", value: "hunter2"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "pin", value: "1234"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "card_number", value: "ask me"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "card_security_code", value: "123"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "verification_code", value: "481516"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "passport_number", value: "X1"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "bank_name", value: "First Bank"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "tax_id", value: "none"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "health_insurance", value: "Blue"))
    }

    @Test func aLongSecretWordInsideAFieldNameIsStillRefused() {
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "mypassword", value: "hunter2"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "passwords", value: "hunter2"))
    }

    @Test func aShortSecretWordInsideAnotherWordIsFine() {
        // "shipping" has "pin" in it and "taxi" has "tax" in it.
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "shipping_address", value: "12 Oak Street"))
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "taxi_company", value: "Acme Cabs"))
    }

    @Test func aSocialSecurityNumberIsRefusedInAnyField() {
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "notes", value: "123-45-6789"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "notes", value: "mine is 123-45-6789 thanks"))
    }

    @Test func aCardNumberIsRefusedEvenInAPhoneField() {
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "notes", value: "4111 1111 1111 1111"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "phone", value: "4111 1111 1111 1111"))
    }

    @Test func longNumbersAreKeptOnlyInPhoneFields() {
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "phone", value: "+1 (415) 555-0132"))
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "work_phone", value: "+1 (415) 555-0132"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "notes", value: "+1 (415) 555-0132"))
        // Sixteen digits that don't pass the card check are just a long number.
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "phone", value: "4111 1111 1111 1112"))
    }

    @Test func nineDigitsIsWhereANumberBecomesTooLong() {
        #expect(DottieFormDetails.isSafeToSave(fieldKey: "member_number", value: "12345678"))
        #expect(!DottieFormDetails.isSafeToSave(fieldKey: "member_number", value: "123456789"))
    }
}

@MainActor
struct FormDetailsFieldNameTests {

    @Test func fieldNamesBecomeLowercaseWordsJoinedByUnderscores() {
        #expect(DottieFormDetails.fieldKey("Favourite colour") == "favourite_colour")
        #expect(DottieFormDetails.fieldKey("  Address line 2: ") == "address_line_2")
        #expect(DottieFormDetails.fieldKey("") == "")
    }

    @Test func commonSpellingsShareOneName() {
        #expect(DottieFormDetails.fieldKey("E-mail Address") == "email")
        #expect(DottieFormDetails.fieldKey("Name") == "full_name")
        #expect(DottieFormDetails.fieldKey("Surname") == "last_name")
        #expect(DottieFormDetails.fieldKey("Phone Number") == "phone")
        #expect(DottieFormDetails.fieldKey("Address Line 1") == "street_address")
        #expect(DottieFormDetails.fieldKey("DOB") == "date_of_birth")
        #expect(DottieFormDetails.fieldKey("Organisation") == "company")
    }

    @Test func aZipCodeIsSavedAlthoughItsNameHasCodeInIt() {
        let zipCodeFieldKey = DottieFormDetails.fieldKey("Zip Code")
        #expect(zipCodeFieldKey == "postcode")
        #expect(DottieFormDetails.isSafeToSave(fieldKey: zipCodeFieldKey, value: "90210"))
    }
}

@MainActor
struct FormLookingTaskTests {

    @Test func requestsAboutFormsLookLikeForms() {
        #expect(DottieFormDetails.taskLooksLikeForm("fill out the contact form"))
        #expect(DottieFormDetails.taskLooksLikeForm("Sign me up for the newsletter"))
        #expect(DottieFormDetails.taskLooksLikeForm("book a table for two"))
        #expect(DottieFormDetails.taskLooksLikeForm("Create an account on GitHub"))
    }

    @Test func otherRequestsDoNot() {
        #expect(!DottieFormDetails.taskLooksLikeForm("open safari"))
        #expect(!DottieFormDetails.taskLooksLikeForm("scroll down"))
        #expect(!DottieFormDetails.taskLooksLikeForm("what's the weather"))
    }

    @Test func aFormWordInsideALongerWordDoesNotCount() {
        #expect(!DottieFormDetails.taskLooksLikeForm("read my notebook"))
        #expect(!DottieFormDetails.taskLooksLikeForm("open facebook"))
        #expect(!DottieFormDetails.taskLooksLikeForm("show the performance tab"))
    }
}

@MainActor
struct TaskGoalSizeTests {

    @Test func oneQuickActionIsShort() {
        #expect(DottieTaskGoals.size(of: "scroll down") == .short)
        #expect(DottieTaskGoals.size(of: "open safari") == .short)
        #expect(DottieTaskGoals.size(of: "play") == .short)
    }

    @Test func politeWordsInFrontDoNotChangeTheSize() {
        #expect(DottieTaskGoals.size(of: "hey dottie can you please scroll down") == .short)
    }

    @Test func askingForTheClickItselfIsShortEvenOnAGoalWord() {
        #expect(DottieTaskGoals.size(of: "click sign in") == .short)
        #expect(DottieTaskGoals.size(of: "click the send button") == .short)
    }

    @Test func aCommonGoalIsLong() {
        #expect(DottieTaskGoals.size(of: "sign in with my work account") == .long)
        #expect(DottieTaskGoals.size(of: "download the report") == .long)
    }

    @Test func severalThingsInARowAreLong() {
        #expect(DottieTaskGoals.size(of: "open opera and search kaggle") == .long)
        #expect(DottieTaskGoals.size(of: "open the page, scroll down") == .long)
        #expect(DottieTaskGoals.size(of: "click send and then close the tab") == .long)
    }

    @Test func manyWordsAreLong() {
        let fifteenWordRequest = "please open the big blue folder on my desktop called holiday pictures from last summer"
        #expect(DottieTaskGoals.size(of: fifteenWordRequest) == .long)
    }

    @Test func wordsThatSayNeitherAreUnsure() {
        #expect(DottieTaskGoals.size(of: "the settings page") == .unsure)
    }
}

@MainActor
struct TaskGoalTemplateTests {

    @Test func aCommonRequestGetsItsReadyMadeGoal() {
        #expect(DottieTaskGoals.template(for: "Download the report")?.goal == "Download what the user asked for")
        #expect(DottieTaskGoals.template(for: "log out of Slack")?.goal == "Sign the user out")
        #expect(DottieTaskGoals.template(for: "scroll down")?.goal == nil)
    }

    @Test func signingInComesWithItsNotDoneSigns() {
        let signInNotDoneSigns = DottieTaskGoals.notDoneSigns(for: "Log me back into Slack")
        #expect(signInNotDoneSigns.contains("choose an account"))
        #expect(signInNotDoneSigns.contains("enter your password"))
        #expect(DottieTaskGoals.notDoneSigns(for: "download the file").isEmpty)
    }

    @Test func aGoalIsNotFinishedByOneClick() {
        #expect(DottieTaskGoals.clickLeavesGoalUnfinished(request: "sign in with this account"))
        #expect(DottieTaskGoals.clickLeavesGoalUnfinished(request: "Send the email to Sam"))
        #expect(DottieTaskGoals.clickLeavesGoalUnfinished(request: "please log out"))
    }

    @Test func askingForTheClickOrWhereSomethingIsFinishesWithIt() {
        #expect(!DottieTaskGoals.clickLeavesGoalUnfinished(request: "click sign in"))
        #expect(!DottieTaskGoals.clickLeavesGoalUnfinished(request: "please click sign in"))
        #expect(!DottieTaskGoals.clickLeavesGoalUnfinished(request: "where is the download button"))
        #expect(!DottieTaskGoals.clickLeavesGoalUnfinished(request: "show me how to install it"))
    }

    @Test func requestsWithNoCommonGoalAreFinishedByTheirAction() {
        #expect(!DottieTaskGoals.clickLeavesGoalUnfinished(request: "scroll down"))
        #expect(!DottieTaskGoals.clickLeavesGoalUnfinished(request: "   "))
    }
}

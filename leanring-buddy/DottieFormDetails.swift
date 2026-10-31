//
//  DottieFormDetails.swift
//  leanring-buddy
//
//  The user's own everyday details for forms (name, email, phone, address,
//  company...). A screen job that fills a form gets them up front, and when
//  it asks the user for a detail it doesn't have (ask_user with a field),
//  the answer is saved here so the next form doesn't ask again. A question
//  about a detail that's already saved is answered from here without
//  bothering the user.
//
//  Passwords, card and bank numbers, ID and passport numbers, codes and
//  security answers are never saved: both the field's name and the value
//  are checked before anything is written.
//
//  Kept only on the Mac, in Application Support/Dottie/FormDetails.json.
//  Home → Profile → Form details shows, edits and deletes them.
//

import Combine
import Foundation

@MainActor
final class DottieFormDetails: ObservableObject {
    static let shared = DottieFormDetails()

    struct Detail: Codable, Identifiable, Equatable {
        /// The field's key, like "email" or "street_address".
        var field: String
        var value: String
        var updatedAt: Date
        var id: String { field }

        /// "street_address" → "Street address", for the Home list.
        var readableFieldName: String {
            let spacedName = field.replacingOccurrences(of: "_", with: " ")
            return spacedName.prefix(1).uppercased() + spacedName.dropFirst()
        }
    }

    /// The field names screen jobs are asked to use, so the same detail is
    /// found again on the next form.
    static let suggestedFieldNames = [
        "full_name", "first_name", "last_name", "email", "phone",
        "street_address", "address_line_2", "city", "state", "postcode", "country",
        "date_of_birth", "company", "job_title", "website"
    ]

    @Published private(set) var details: [Detail] = []
    /// Off: form jobs get nothing from here and nothing new is saved.
    @Published var isRememberingEnabled: Bool {
        didSet { UserDefaults.standard.set(isRememberingEnabled, forKey: Self.rememberingEnabledDefaultsKey) }
    }

    private static let rememberingEnabledDefaultsKey = "DottieFormDetailsRememberingEnabled"
    private static let maximumValueLength = 200
    private let fileURL: URL

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dottieFolderURL = applicationSupportURL.appendingPathComponent("Dottie", isDirectory: true)
        try? FileManager.default.createDirectory(at: dottieFolderURL, withIntermediateDirectories: true)
        fileURL = dottieFolderURL.appendingPathComponent("FormDetails.json")
        isRememberingEnabled = UserDefaults.standard.object(forKey: Self.rememberingEnabledDefaultsKey) as? Bool ?? true
        details = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([Detail].self, from: $0) } ?? []
    }

    // MARK: - Reading

    func value(forField field: String) -> String? {
        guard isRememberingEnabled else { return nil }
        let fieldKey = Self.fieldKey(field)
        if let exactMatch = details.first(where: { $0.field == fieldKey }) {
            return exactMatch.value
        }
        // "name" asked when "full_name" is saved, and the other way round.
        let fieldAliases: [String: [String]] = [
            "name": ["full_name"], "full_name": ["name"],
            "phone_number": ["phone"], "phone": ["phone_number", "mobile"], "mobile": ["phone"],
            "email_address": ["email"], "email": ["email_address"],
            "zip": ["postcode"], "zip_code": ["postcode"], "postal_code": ["postcode"], "postcode": ["zip", "zip_code", "postal_code"],
            "address": ["street_address"], "street_address": ["address"],
            "birthday": ["date_of_birth"], "date_of_birth": ["birthday"]
        ]
        for aliasKey in fieldAliases[fieldKey] ?? [] {
            if let aliasMatch = details.first(where: { $0.field == aliasKey }) {
                return aliasMatch.value
            }
        }
        return nil
    }

    /// What a form job is told up front. Empty when nothing's saved or
    /// remembering is off.
    var promptTextForFormJob: String {
        guard isRememberingEnabled, !details.isEmpty else { return "" }
        let detailLines = details.map { "- \($0.field): \($0.value)" }.joined(separator: "\n")
        return "The user's saved form details (fill these in without asking; ask_user only for what isn't here):\n" + detailLines
    }

    /// Words that make a screen job look like it fills in a form, so only
    /// those jobs get the saved details sent along with the screenshots.
    static func taskLooksLikeForm(_ taskText: String) -> Bool {
        let lowercasedTask = taskText.lowercased()
        let formWordsPattern = #"\b(form|forms|fill|filling|sign me up|sign up|signup|register|registration|apply|application|checkout|check out|shipping|billing|delivery address|contact details|rsvp|survey|enrol|enroll|book|booking|reserve|subscribe|create an account|create my account|make an account)\b"#
        return lowercasedTask.range(of: formWordsPattern, options: .regularExpression) != nil
    }

    // MARK: - Saving

    enum SaveResult: Equatable {
        case saved
        case refusedSensitive
        case refusedEmpty
        case rememberingOff
    }

    @discardableResult
    func save(field: String, value: String) -> SaveResult {
        guard isRememberingEnabled else { return .rememberingOff }
        let fieldKey = Self.fieldKey(field)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fieldKey.isEmpty, !trimmedValue.isEmpty, trimmedValue.count <= Self.maximumValueLength,
              !Self.isNonAnswer(trimmedValue) else { return .refusedEmpty }
        guard Self.isSafeToSave(fieldKey: fieldKey, value: trimmedValue) else { return .refusedSensitive }
        details.removeAll { $0.field == fieldKey }
        details.append(Detail(field: fieldKey, value: trimmedValue, updatedAt: Date()))
        details.sort { Self.sortOrder(of: $0.field) < Self.sortOrder(of: $1.field) }
        writeToDisk()
        return .saved
    }

    func forget(field: String) {
        let fieldKey = Self.fieldKey(field)
        details.removeAll { $0.field == fieldKey }
        writeToDisk()
    }

    func forgetAll() {
        details = []
        writeToDisk()
    }

    private func writeToDisk() {
        guard let detailsData = try? JSONEncoder().encode(details) else { return }
        try? detailsData.write(to: fileURL, options: .atomic)
    }

    // MARK: - What's never saved

    /// Words in a field's name that mean it's a secret or a number that
    /// could be used to steal money or someone's identity.
    private static let sensitiveFieldWords = [
        "password", "passcode", "passphrase", "pin", "secret", "token", "api_key", "apikey",
        "card", "cvv", "cvc", "csc", "expiry", "expiration", "security_code",
        "iban", "swift", "bic", "routing", "sort_code", "account_number", "bank",
        "ssn", "social_security", "national_insurance", "nino", "tax", "tin", "ein", "vat_number",
        "passport", "license", "licence", "id_number", "national_id", "identity", "nric", "aadhaar", "aadhar", "pan_number",
        "otp", "code", "verification", "one_time", "2fa", "mfa",
        "security_question", "security_answer", "maiden", "medical", "insurance_number", "health"
    ]

    static func isSafeToSave(fieldKey: String, value: String) -> Bool {
        let fieldWords = fieldKey.split(separator: "_").map(String.init)
        for sensitiveWord in sensitiveFieldWords {
            if sensitiveWord.contains("_") {
                if fieldKey.contains(sensitiveWord) { return false }
            } else if fieldWords.contains(sensitiveWord) || (sensitiveWord.count >= 6 && fieldKey.contains(sensitiveWord)) {
                return false
            }
        }
        // The value itself: something shaped like a US social security
        // number, or a long run of digits that passes the card check.
        if value.range(of: #"\b\d{3}-\d{2}-\d{4}\b"#, options: .regularExpression) != nil {
            return false
        }
        let digitsOnly = value.filter(\.isNumber)
        if (13...19).contains(digitsOnly.count), passesLuhnCheck(digitsOnly) {
            return false
        }
        // Long numbers belong only in a phone field; anywhere else they're
        // more likely an account or ID number.
        let isPhoneField = fieldWords.contains { ["phone", "mobile", "cell", "telephone", "tel", "fax"].contains($0) }
        if !isPhoneField, digitsOnly.count >= 9 {
            return false
        }
        return true
    }

    private static func passesLuhnCheck(_ digits: String) -> Bool {
        var runningSum = 0
        for (offsetFromRight, character) in digits.reversed().enumerated() {
            guard var digitValue = character.wholeNumberValue else { return false }
            if offsetFromRight % 2 == 1 {
                digitValue *= 2
                if digitValue > 9 { digitValue -= 9 }
            }
            runningSum += digitValue
        }
        return runningSum % 10 == 0
    }

    /// "skip", "I don't know" and the like aren't details.
    private static func isNonAnswer(_ value: String) -> Bool {
        let lowercasedValue = value.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let nonAnswers: Set<String> = [
            "skip", "skip it", "no", "none", "n/a", "na", "nothing", "leave it", "leave it blank", "leave it empty",
            "i don't know", "i dont know", "don't know", "dont know", "not sure", "never mind", "nevermind", "stop", "cancel"
        ]
        return nonAnswers.contains(lowercasedValue)
    }

    // MARK: - Field names

    /// "E-mail Address" → "e_mail_address" → known key "email" when close.
    static func fieldKey(_ field: String) -> String {
        let lowercasedField = field.lowercased()
        let underscoredField = lowercasedField
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let knownSpellings: [String: String] = [
            "e_mail": "email", "e_mail_address": "email", "email_address": "email",
            "name": "full_name", "your_name": "full_name", "fullname": "full_name",
            "first": "first_name", "given_name": "first_name", "firstname": "first_name",
            "last": "last_name", "surname": "last_name", "family_name": "last_name", "lastname": "last_name",
            "phone_number": "phone", "mobile_number": "phone", "mobile": "phone", "telephone": "phone", "cell": "phone",
            "address": "street_address", "address_line_1": "street_address", "street": "street_address",
            "zip": "postcode", "zip_code": "postcode", "zipcode": "postcode", "postal_code": "postcode", "post_code": "postcode",
            "town": "city", "province": "state", "region": "state",
            "birthday": "date_of_birth", "dob": "date_of_birth", "birth_date": "date_of_birth",
            "company_name": "company", "organisation": "company", "organization": "company", "employer": "company",
            "title": "job_title", "role": "job_title"
        ]
        return knownSpellings[underscoredField] ?? underscoredField
    }

    private static func sortOrder(of fieldKey: String) -> Int {
        suggestedFieldNames.firstIndex(of: fieldKey) ?? suggestedFieldNames.count
    }
}

// MARK: - Voice tool

@MainActor
enum DottieFormDetailsTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "form_details",
                description: "The user's saved everyday details for filling in forms (name, email, phone, address, company...), kept only on their Mac. list shows them. save keeps one the user told you (field like full_name, email, phone, street_address, city, state, postcode, country, date_of_birth, company, job_title). forget deletes one field, forget_all clears them. Before filling a form with the browser tool, list them and fill what's there; ask only for what's missing, then save the answer. Passwords, card, bank, ID and passport numbers and codes are refused by the app: never try to save them.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["list", "save", "forget", "forget_all"]],
                        "field": ["type": "STRING", "description": "save and forget: the field's name, like email or street_address."],
                        "value": ["type": "STRING", "description": "save: what the user said, exactly."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice],
                run: { arguments in formDetails(arguments) }
            )
        ]
    }

    static var voicePromptSection: String {
        "filling in forms: screen jobs already get the user's saved form details and save new ones the user answers, so just pass the whole job to do_task_on_screen. when the user tells you their own details for forms ('my address is …'), save them with form_details. never save passwords, card, bank, ID or passport numbers."
    }

    private static func formDetails(_ arguments: [String: Any]) -> String {
        let store = DottieFormDetails.shared
        switch arguments.dottieString("action")?.lowercased() ?? "list" {
        case "save":
            guard let field = arguments.dottieString("field"), let value = arguments.dottieString("value") else {
                return "say which field and what to put."
            }
            switch store.save(field: field, value: value) {
            case .saved:
                return "saved \(DottieFormDetails.fieldKey(field)) for future forms."
            case .refusedSensitive:
                return "not saved: that looks like a password, card, bank or ID number, which Dottie never keeps. use it just for this form."
            case .refusedEmpty:
                return "nothing to save."
            case .rememberingOff:
                return "not saved: the user turned off remembering form details (Home → Profile)."
            }
        case "forget":
            guard let field = arguments.dottieString("field") else { return "say which field to forget." }
            store.forget(field: field)
            return "forgot \(DottieFormDetails.fieldKey(field))."
        case "forget_all":
            store.forgetAll()
            return "forgot every saved form detail."
        default:
            guard store.isRememberingEnabled else { return "remembering form details is off (Home → Profile)." }
            guard !store.details.isEmpty else { return "no form details saved yet. they're saved when the user answers a form job's question, or tells you them." }
            return store.details.map { "\($0.field): \($0.value)" }.joined(separator: "\n")
        }
    }
}

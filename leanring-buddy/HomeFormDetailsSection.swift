//
//  HomeFormDetailsSection.swift
//  leanring-buddy
//
//  Home → Profile → Form details: what Dottie fills into forms without
//  asking (DottieFormDetails), each one editable and deletable, plus the
//  switch that turns remembering them off.
//

import SwiftUI

struct HomeFormDetailsSection: View {
    @ObservedObject private var formDetails = DottieFormDetails.shared
    /// The field being edited and its text, while its box is open.
    @State private var editingField: String?
    @State private var editingValueText = ""
    @State private var newFieldNameText = ""
    @State private var newValueText = ""
    @State private var lastRefusalMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Remember my details for forms", isOn: $formDetails.isRememberingEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .pointerCursor()

            Text("When a form job asks you for something like your email or address, Dottie keeps the answer here, only on this Mac, and fills it in next time without asking. Passwords, card, bank, ID and passport numbers and codes are never saved.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if formDetails.isRememberingEnabled {
                if formDetails.details.isEmpty {
                    Text("Nothing saved yet.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(formDetails.details) { detail in
                            detailRow(detail)
                            if detail.id != formDetails.details.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.surface1)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                            )
                    )
                }

                addDetailRow

                if let lastRefusalMessage {
                    Text(lastRefusalMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                }

                if !formDetails.details.isEmpty {
                    Button("Forget all form details") {
                        formDetails.forgetAll()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .pointerCursor()
                }
            }
        }
    }

    private func detailRow(_ detail: DottieFormDetails.Detail) -> some View {
        HStack(spacing: 10) {
            Text(detail.readableFieldName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 120, alignment: .leading)
            if editingField == detail.field {
                TextField("Value", text: $editingValueText, onCommit: { saveEditedValue(forField: detail.field) })
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Save") { saveEditedValue(forField: detail.field) }
                    .pointerCursor()
                Button("Cancel") { editingField = nil }
                    .pointerCursor()
            } else {
                Text(detail.value)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    editingField = detail.field
                    editingValueText = detail.value
                    lastRefusalMessage = nil
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit")
                .pointerCursor()
                Button {
                    formDetails.forget(field: detail.field)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget this one")
                .pointerCursor()
            }
        }
        .padding(.vertical, 8)
    }

    private var addDetailRow: some View {
        HStack(spacing: 8) {
            TextField("Field, like email", text: $newFieldNameText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 150)
            TextField("Value", text: $newValueText, onCommit: addNewDetail)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Button("Add", action: addNewDetail)
                .disabled(newFieldNameText.trimmingCharacters(in: .whitespaces).isEmpty || newValueText.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor()
        }
    }

    private func saveEditedValue(forField field: String) {
        // Saving an emptied box means forget that detail.
        if editingValueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            formDetails.forget(field: field)
            lastRefusalMessage = nil
            editingField = nil
            return
        }
        let saveResult = formDetails.save(field: field, value: editingValueText)
        lastRefusalMessage = Self.refusalMessage(for: saveResult)
        if saveResult == .saved {
            editingField = nil
        }
    }

    private func addNewDetail() {
        let saveResult = formDetails.save(field: newFieldNameText, value: newValueText)
        lastRefusalMessage = Self.refusalMessage(for: saveResult)
        if saveResult == .saved {
            newFieldNameText = ""
            newValueText = ""
        }
    }

    private static func refusalMessage(for saveResult: DottieFormDetails.SaveResult) -> String? {
        switch saveResult {
        case .saved, .rememberingOff:
            return nil
        case .refusedSensitive:
            return "Not saved: that looks like a password, card, bank or ID number, which Dottie never keeps."
        case .refusedEmpty:
            return "Not saved: type a field name and a value."
        }
    }
}

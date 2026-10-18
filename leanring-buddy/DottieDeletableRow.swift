//
//  DottieDeletableRow.swift
//  leanring-buddy
//
//  Lets the user delete one message in Home → Conversation or a Dot's
//  chat: a trash button appears on hover, and right-click has Copy and
//  Delete.
//

import AppKit
import SwiftUI

private struct DeletableRowModifier: ViewModifier {
    let copyText: String
    let onDelete: () -> Void
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(DS.Colors.surface3))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Delete this message")
                    .transition(.opacity)
                }
            }
            .onHover { isHovered = $0 }
            .contextMenu {
                if !copyText.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyText, forType: .string)
                    }
                }
                Button("Delete", role: .destructive, action: onDelete)
            }
    }
}

extension View {
    func deletableRow(copyText: String, onDelete: @escaping () -> Void) -> some View {
        modifier(DeletableRowModifier(copyText: copyText, onDelete: onDelete))
    }
}

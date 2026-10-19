import AppKit
import SwiftUI

/// Keeps typing separate from a threshold's value. A formatted SwiftUI TextField writes every parseable
/// numeric prefix; this native field commits only on Return, Tab, or leaving the field.
struct ThresholdNumberField: NSViewRepresentable {
    let name: String
    @Binding var value: Double?
    let resetVersion: Int
    let currentResetVersion: () -> Int
    let invalidText: () -> Void
    var prepareCommit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .right
        field.placeholderString = "None"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.isEnabled = context.environment.isEnabled
        field.setAccessibilityLabel(name)
        field.delegate = context.coordinator
        context.coordinator.update(self, field: field, force: true)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.isEnabled = context.environment.isEnabled
        context.coordinator.update(self, field: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var parent: ThresholdNumberField
        private var displayedValue: Double?
        private var editVersion: Int

        init(parent: ThresholdNumberField) {
            self.parent = parent
            displayedValue = parent.value
            editVersion = parent.resetVersion
        }

        func update(_ parent: ThresholdNumberField, field: NSTextField, force: Bool = false) {
            self.parent = parent
            let version = parent.currentResetVersion()
            // Unrelated view updates must not replace text the user is still typing. A changed value or
            // reset, however, replaces even active text so a stale edit cannot overwrite it later.
            if force || parent.value != displayedValue || version != editVersion {
                field.stringValue = parent.value.map { $0.formatted(.number) } ?? ""
                displayedValue = parent.value
                editVersion = version
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Reconcile here, rather than during SwiftUI view updates, before validating this edit session.
            parent.prepareCommit()
            guard parent.currentResetVersion() == editVersion, parent.value == displayedValue else {
                update(parent, field: field, force: true)
                return
            }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                parent.value = nil
            } else if let parsed = try? FloatingPointFormatStyle<Double>.number.consuming(
                text, startingAt: text.startIndex, in: text.startIndex..<text.endIndex),
                parsed.upperBound == text.endIndex
            {
                parent.value = parsed.output
            } else {
                parent.invalidText()
            }
            displayedValue = parent.value
        }
    }
}

import SwiftUI
import AppKit
import TypesterCore

struct TeachDictionaryView: View {
    let transcript: String
    var onSaved: (() -> Void)?
    var onCancel: (() -> Void)?

    @State private var wrong: String = ""
    @State private var right: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Teach dictionary")
                .font(.title2.weight(.semibold))

            Text("Select the wrong word in the transcript (or type it), then enter the correct spelling. Typester replaces it before pasting and sends the correct term to Soniox.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Last transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SelectableTranscriptView(text: transcript) { selection in
                    if !selection.isEmpty {
                        wrong = selection
                    }
                }
                .frame(minHeight: 80, maxHeight: 120)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Heard (wrong)", text: $wrong)
                    .textFieldStyle(.roundedBorder)

                TextField("Correct (right)", text: $right)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel?()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var canSave: Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        return !w.isEmpty && !r.isEmpty && w != r
    }

    private func save() {
        let success = SettingsStore.shared.addCorrection(wrong: wrong, right: right)
        if success {
            errorMessage = nil
            onSaved?()
        } else {
            errorMessage = "Enter different wrong and correct words."
        }
    }
}

private struct SelectableTranscriptView: NSViewRepresentable {
    let text: String
    var onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 0, height: 0)

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.onSelectionChange = onSelectionChange
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChange: (String) -> Void
        weak var textView: NSTextView?

        init(onSelectionChange: @escaping (String) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let selected = textView.string as NSString
            let range = textView.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= selected.length else { return }
            onSelectionChange(selected.substring(with: range))
        }
    }
}

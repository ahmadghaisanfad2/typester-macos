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
    @FocusState private var wrongFocused: Bool
    @FocusState private var rightFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Teach dictionary")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Codex.text)

                Text("Select the wrong word in the transcript (or type it), then enter the correct spelling. Typester replaces it before pasting and sends the correct term to Soniox.")
                    .font(.system(size: 12))
                    .foregroundStyle(Codex.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            VStack(alignment: .leading, spacing: 6) {
                Text("Last transcript")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Codex.textSecondary)

                SelectableTranscriptView(text: transcript) { selection in
                    if !selection.isEmpty {
                        wrong = selection
                    }
                }
                .frame(minHeight: 78, maxHeight: 110)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Codex.surfaceInset))
                .overlay(HairlineBorder(cornerRadius: 8))
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    correctionField(label: "Heard", placeholder: "wrong word", text: $wrong, focused: $wrongFocused) {
                        rightFocused = true
                    }

                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Codex.textTertiary)
                        .padding(.top, 20)

                    correctionField(label: "Correct", placeholder: "right word", text: $right, focused: $rightFocused, submit: save)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)

            Rectangle()
                .fill(Codex.hairline)
                .frame(height: 1)

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
            .padding(14)
        }
        .frame(width: 460)
        .background(Codex.background)
        .tint(Codex.green)
        .onAppear {
            wrongFocused = true
        }
    }

    private func correctionField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        focused: FocusState<Bool>.Binding,
        submit: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Codex.textSecondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.mono(12.5))
                .fieldCard(focused: focused.wrappedValue)
                .focused(focused)
                .onSubmit {
                    submit?()
                }
        }
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
        textView.font = .systemFont(ofSize: 12.5)
        textView.textColor = .labelColor
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

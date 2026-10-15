import SwiftUI
import AppKit

/// The dictation-detail modal, presented once at window level by the dashboard shell.
struct MacDictationDetailOverlay: View {
    let entry: DictationHistoryEntry
    let onClose: () -> Void

    @State private var copiedSectionID: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            card
                .frame(width: 760, height: 600)
                .accessibilityAddTraits(.isModal)
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Divider().overlay(KleioPalette.stroke)

            metaRow

            Divider().overlay(KleioPalette.stroke)

            sections
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KleioPalette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(KleioPalette.stroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 24, y: 10)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            KleioSourceAppIcon(entry: entry, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.isImportedAudio ? "Imported audio" : (entry.sourceAppDisplayName ?? "Unknown app"))
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(KleioPalette.ink)

                Text(entry.timestamp.formatted(date: .complete, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(KleioPalette.secondary)
            }

            Spacer()

            closeButton
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(KleioPalette.ink)
                .frame(width: 28, height: 28)
                .background(KleioPalette.selection, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
    }

    // MARK: Meta row

    private var metaRow: some View {
        HStack(spacing: 10) {
            metaChip(title: "Style", value: entry.styleName ?? "—")
            metaChip(title: "Words", value: KleioFormat.int(entry.wordCount))
            // Recovered sessions carry a floored duration, so speed and length would be fiction.
            metaChip(title: "Speed", value: entry.isSpeedEligible ? KleioFormat.wpm(entry.wordsPerMinute) : "—")
            metaChip(title: "Duration", value: entry.isFailedRawFallback ? "—" : KleioFormat.duration(entry.audioDuration))
        }
    }

    private func metaChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(KleioPalette.secondary)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KleioPalette.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            KleioPalette.selection.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(KleioPalette.stroke, lineWidth: 1)
        )
    }

    // MARK: Sections

    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let failureNote = entry.failureNote {
                    detailSection(
                        title: "Recovered session",
                        bodyText: failureNote,
                        titleColor: KleioPalette.attention
                    )
                }

                detailSection(id: "cleaned", title: "Cleaned text", bodyText: entry.cleanedDisplayText, showsCopyButton: entry.hasCleanedText)
                detailSection(id: "raw", title: "Raw dictation", bodyText: entry.rawDisplayText, showsCopyButton: entry.hasRawText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailSection(
        id: String = "",
        title: String,
        bodyText: String,
        titleColor: Color = KleioPalette.secondary,
        showsCopyButton: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                KleioSectionTitle(title, color: titleColor)
                if showsCopyButton {
                    Spacer()
                    sectionCopyButton(id: id, text: bodyText)
                }
            }

            Text(bodyText)
                .font(.system(size: 14))
                .foregroundStyle(KleioPalette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    Color.white.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(KleioPalette.stroke, lineWidth: 1)
                )
        }
    }

    private func sectionCopyButton(id: String, text: String) -> some View {
        let isCopied = copiedSectionID == id
        return Button {
            KleioPasteboard.copy(text)
            copiedSectionID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedSectionID == id { copiedSectionID = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                Text(isCopied ? "Copied" : "Copy")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isCopied ? KleioPalette.positive : KleioPalette.secondary)
        }
        .buttonStyle(.plain)
        .kleioPointer()
    }
}

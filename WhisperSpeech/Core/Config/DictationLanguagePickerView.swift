import SwiftUI

struct DictationLanguagePickerOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let searchableText: String
}

struct DictationLanguagePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let selectedID: String
    let options: [DictationLanguagePickerOption]
    let onSelect: (String) -> Void

    @State private var searchText = ""

    private var filteredOptions: [DictationLanguagePickerOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return options }
        return options.filter { option in
            option.searchableText.contains(query)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredOptions, id: \.id) { option in
                    row(for: option)
                }
            }
            .padding(16)
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search languages")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func row(for option: DictationLanguagePickerOption) -> some View {
        Button {
            onSelect(option.id)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .foregroundStyle(.primary)

                    if let subtitle = option.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if option.id == selectedID {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

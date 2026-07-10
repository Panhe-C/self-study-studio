import SwiftUI

struct AIReviewSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let settingsStore: AIReviewSettingsStore

    @State private var endpoint: String
    @State private var model: String
    @State private var apiKey = ""
    @State private var notice: AIReviewSettingsNotice?

    init(settingsStore: AIReviewSettingsStore = AIReviewSettingsStore()) {
        self.settingsStore = settingsStore
        let current = settingsStore.settings()
        _endpoint = State(initialValue: current?.endpoint.absoluteString ?? "")
        _model = State(initialValue: current?.model ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("AI Weekly Review") {
                    TextField("Endpoint", text: $endpoint)
                        .textContentType(.URL)
                        .journalAIConfigurationInputStyle()
                    TextField("Model", text: $model)
                        .journalAIConfigurationInputStyle()
                    SecureField("API Key", text: $apiKey)

                    Text(settingsStore.isConfigured ? "A configured endpoint will be used for future reviews." : "Reviews use the local evidence-based fallback until an endpoint and key are saved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if settingsStore.isConfigured {
                    Section {
                        Button(role: .destructive) {
                            clearAPIKey()
                        } label: {
                            Label("Clear Saved API Key", systemImage: "key.slash")
                        }
                    }
                }
            }
            .navigationTitle("AI Review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert(item: $notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func save() {
        guard let endpointURL = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            notice = AIReviewSettingsNotice(title: "Settings Not Saved", message: "Enter a valid http or https endpoint.")
            return
        }

        do {
            try settingsStore.save(
                settings: AIReviewSettings(endpoint: endpointURL, model: model),
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : apiKey
            )
            dismiss()
        } catch {
            notice = AIReviewSettingsNotice(title: "Settings Not Saved", message: error.localizedDescription)
        }
    }

    private func clearAPIKey() {
        do {
            try settingsStore.clearAPIKey()
            apiKey = ""
            notice = AIReviewSettingsNotice(title: "API Key Cleared", message: "Future reviews will use the local fallback until a new key is saved.")
        } catch {
            notice = AIReviewSettingsNotice(title: "API Key Not Cleared", message: error.localizedDescription)
        }
    }
}

private struct AIReviewSettingsNotice: Identifiable {
    var id = UUID()
    var title: String
    var message: String
}

private extension View {
    @ViewBuilder
    func journalAIConfigurationInputStyle() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }
}

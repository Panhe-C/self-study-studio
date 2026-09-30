import SwiftUI

struct AIReviewSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let settingsStore: AIReviewSettingsStore

    @State private var provider: AIProviderPreset
    @State private var selectedModel: String
    @State private var customEndpoint: String
    @State private var customModel: String
    @State private var apiKey = ""
    @State private var notice: AIReviewSettingsNotice?

    private let initialProvider: AIProviderPreset

    init(settingsStore: AIReviewSettingsStore = AIReviewSettingsStore()) {
        self.settingsStore = settingsStore
        let current = settingsStore.settings()
        let provider = current?.provider ?? .openAI
        let model = current?.model ?? provider.defaultModel ?? ""
        initialProvider = provider
        _provider = State(initialValue: provider)
        _selectedModel = State(initialValue: provider.models.contains(model) ? model : provider.defaultModel ?? "")
        _customEndpoint = State(initialValue: provider == .custom ? current?.endpoint.absoluteString ?? "" : "")
        _customModel = State(initialValue: provider == .custom ? model : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("ai.settings.provider", selection: $provider) {
                        ForEach(AIProviderPreset.allCases) { preset in
                            if preset == .custom {
                                Text("ai.settings.provider.custom").tag(preset)
                            } else {
                                Text(preset.displayName).tag(preset)
                            }
                        }
                    }

                    if provider == .custom {
                        TextField("ai.settings.endpoint", text: $customEndpoint)
                            .textContentType(.URL)
                            .journalAIConfigurationInputStyle()
                        TextField("ai.settings.model", text: $customModel)
                            .journalAIConfigurationInputStyle()
                    } else {
                        Picker("ai.settings.model", selection: $selectedModel) {
                            ForEach(provider.models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }

                        LabeledContent("ai.settings.endpoint") {
                            Text(provider.endpoint?.absoluteString ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    SecureField("ai.settings.api_key", text: $apiKey)

                    Text(selectionIsConfigured ? "ai.settings.configured" : "ai.settings.fallback")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("ai.settings.section")
                } footer: {
                    if provider != .custom {
                        Text("ai.settings.preset_footer")
                    }
                }

                if settingsStore.isConfigured {
                    Section {
                        Button(role: .destructive) {
                            clearAPIKey()
                        } label: {
                            Label("ai.settings.clear_key", systemImage: "key.slash")
                        }
                    }
                }
            }
            .navigationTitle("ai.settings.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ai.settings.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ai.settings.save") { save() }
                }
            }
            .alert(item: $notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("ai.settings.ok"))
                )
            }
            .onChange(of: provider) { newProvider in
                if let defaultModel = newProvider.defaultModel {
                    selectedModel = defaultModel
                }
            }
        }
    }

    private var selectionIsConfigured: Bool {
        provider == initialProvider && settingsStore.isConfigured
    }

    private func save() {
        guard provider == initialProvider || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = AIReviewSettingsNotice(
                title: String(localized: "ai.settings.not_saved"),
                message: String(localized: "ai.settings.key_required")
            )
            return
        }

        let settings: AIReviewSettings
        if provider == .custom {
            guard let endpointURL = URL(string: customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                notice = AIReviewSettingsNotice(
                    title: String(localized: "ai.settings.not_saved"),
                    message: String(localized: "ai.settings.invalid_endpoint")
                )
                return
            }
            settings = AIReviewSettings(
                endpoint: endpointURL,
                model: customModel,
                providerID: AIProviderPreset.custom.rawValue
            )
        } else {
            guard let presetSettings = provider.makeSettings(model: selectedModel) else { return }
            settings = presetSettings
        }

        do {
            try settingsStore.save(
                settings: settings,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : apiKey
            )
            dismiss()
        } catch {
            notice = AIReviewSettingsNotice(title: String(localized: "ai.settings.not_saved"), message: error.localizedDescription)
        }
    }

    private func clearAPIKey() {
        do {
            try settingsStore.clearAPIKey()
            apiKey = ""
            notice = AIReviewSettingsNotice(
                title: String(localized: "ai.settings.key_cleared"),
                message: String(localized: "ai.settings.key_cleared_message")
            )
        } catch {
            notice = AIReviewSettingsNotice(title: String(localized: "ai.settings.key_not_cleared"), message: error.localizedDescription)
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

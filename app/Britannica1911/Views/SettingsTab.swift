import SwiftUI

/// App settings, split into Appearance and Listen (OpenAI TTS) subsections.
struct SettingsTab: View {
    @State private var section: Section = .appearance

    enum Section: String, CaseIterable, Identifiable {
        case appearance, listen
        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance: return "Appearance"
            case .listen:     return "Listen"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                Divider()

                switch section {
                case .appearance: AppearanceSettings()
                case .listen:     ListenSettings()
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Article text size") {
                Picker("Text size", selection: $settings.fontSize) {
                    ForEach(ArticleFontSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: settings.fontSize.pointSize, design: .serif))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Listen (OpenAI credentials + voice)

private struct ListenSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var keyInput = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        Form {
            Section {
                if settings.hasAPIKey {
                    Label("Authenticated", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not authenticated", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }

                SecureField("sk-…", text: $keyInput)
                    .focused($keyFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    #endif

                HStack {
                    Button("Save") {
                        settings.apiKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        keyFocused = false
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if settings.hasAPIKey {
                        Spacer()
                        Button("Clear", role: .destructive) {
                            settings.apiKey = ""
                            keyInput = ""
                        }
                    }
                }
            } header: {
                Text("OpenAI API key")
            } footer: {
                Text("Used to synthesize article audio via OpenAI's text-to-speech API. Stored securely in the Keychain and kept on this device.")
            }

            Section("Voice") {
                Picker("Voice", selection: $settings.voice) {
                    ForEach(TTSVoice.allCases) { Text($0.label).tag($0) }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif
                .disabled(!settings.hasAPIKey)
            }
        }
        .onAppear { keyInput = settings.apiKey }
    }
}

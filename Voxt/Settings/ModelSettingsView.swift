import SwiftUI
import AppKit

struct ModelSettingsView: View {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    @AppStorage(AppPreferenceKey.transcriptionEngine) private var engineRaw = TranscriptionEngine.mlxAudio.rawValue
    @AppStorage(AppPreferenceKey.enhancementMode) private var enhancementModeRaw = EnhancementMode.off.rawValue
    @AppStorage(AppPreferenceKey.enhancementSystemPrompt) private var systemPrompt = AppPreferenceKey.defaultEnhancementPrompt
    @AppStorage(AppPreferenceKey.mlxModelRepo) private var modelRepo = MLXModelManager.defaultModelRepo
    @AppStorage(AppPreferenceKey.useHfMirror) private var useHfMirror = false

    @ObservedObject var mlxModelManager: MLXModelManager

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw) ?? .mlxAudio
    }

    private var appleIntelligenceAvailable: Bool {
        if #available(macOS 26.0, *) {
            return TextEnhancer.isAvailable
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(title: "Transcription")

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Engine")
                        .font(.headline)

                    Picker("Engine", selection: $engineRaw) {
                        ForEach(TranscriptionEngine.allCases) { engine in
                            Text(engine.title).tag(engine.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)

                    Text(selectedEngine.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if selectedEngine == .mlxAudio {
                        mlxModelSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Text Enhancement")
                        .font(.headline)

                    Picker("Enhancement", selection: $enhancementModeRaw) {
                        Text(EnhancementMode.off.title).tag(EnhancementMode.off.rawValue)
                        Text(EnhancementMode.appleIntelligence.title)
                            .tag(EnhancementMode.appleIntelligence.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)

                    if !appleIntelligenceAvailable {
                        Text("Apple Intelligence is not available on this Mac right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if enhancementModeRaw == EnhancementMode.appleIntelligence.rawValue {
                        Divider()

                        Text("System Prompt")
                            .font(.subheadline.weight(.medium))

                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 100)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.quaternary.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )

                        HStack {
                            Text("Customise how Apple Intelligence enhances your transcriptions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Reset to Default") {
                                systemPrompt = AppPreferenceKey.defaultEnhancementPrompt
                            }
                            .controlSize(.small)
                            .disabled(systemPrompt == AppPreferenceKey.defaultEnhancementPrompt)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .onAppear {
            let canonicalRepo = MLXModelManager.canonicalModelRepo(modelRepo)
            if canonicalRepo != modelRepo {
                modelRepo = canonicalRepo
            }
            mlxModelManager.updateModel(repo: canonicalRepo)
            updateMirrorSetting()
        }
        .onChange(of: modelRepo) { _, newValue in
            let canonicalRepo = MLXModelManager.canonicalModelRepo(newValue)
            if canonicalRepo != newValue {
                modelRepo = canonicalRepo
                return
            }
            mlxModelManager.updateModel(repo: canonicalRepo)
        }
        .onChange(of: useHfMirror) { _, _ in
            updateMirrorSetting()
        }
    }

    @ViewBuilder
    private var mlxModelSection: some View {
        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.subheadline.weight(.medium))

            Picker("Model", selection: $modelRepo) {
                ForEach(MLXModelManager.availableModels) { model in
                    Text(model.title).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)

            if let model = MLXModelManager.availableModels.first(where: { $0.id == modelRepo }) {
                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("Download size:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $useHfMirror) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use China mirror")
                    Text("Download from https://hf-mirror.com/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }

        switch mlxModelManager.state {
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 8) {
                Text("Model needs to be downloaded from Hugging Face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Download Model") {
                    startModelDownload()
                }
                .controlSize(.small)
            }

        case .downloading(let progress, let completed, let total):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 160)
                        .controlSize(.small)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Cancel") {
                        mlxModelManager.cancelDownload()
                    }
                    .controlSize(.small)
                }
                Text(downloadProgressText(completed: completed, total: total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .downloaded:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Model downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !mlxModelManager.modelSizeOnDisk.isEmpty {
                    Text("Size: \(mlxModelManager.modelSizeOnDisk)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Remove Model", role: .destructive) {
                    mlxModelManager.deleteModel()
                }
                .controlSize(.small)
            }

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Model ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !mlxModelManager.modelSizeOnDisk.isEmpty {
                    Text("(\(mlxModelManager.modelSizeOnDisk))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Retry Download") {
                    startModelDownload(resetExisting: true)
                }
                .controlSize(.small)
            }
        }
    }

    private var sizeText: String {
        switch mlxModelManager.sizeState {
        case .unknown:
            return "Unknown"
        case .loading:
            return "Loading…"
        case .ready(_, let text):
            return text
        case .error:
            return "Unknown"
        }
    }

    private func downloadProgressText(completed: Int64, total: Int64) -> String {
        let completedText = Self.byteFormatter.string(fromByteCount: completed)
        if total > 0 {
            let totalText = Self.byteFormatter.string(fromByteCount: total)
            return "Downloaded: \(completedText) / \(totalText)"
        }
        return "Downloaded: \(completedText)"
    }

    private func startModelDownload(resetExisting: Bool = false) {
        if resetExisting {
            mlxModelManager.deleteModel()
        }
        Task {
            await mlxModelManager.downloadModel()
        }
    }

    private func updateMirrorSetting() {
        let url = useHfMirror ? MLXModelManager.mirrorHubBaseURL : MLXModelManager.defaultHubBaseURL
        mlxModelManager.updateHubBaseURL(url)
    }
}

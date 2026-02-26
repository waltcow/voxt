import Foundation
import AVFoundation
import Combine
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTT

@MainActor
class MLXTranscriber: ObservableObject, TranscriberProtocol {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText = ""
    @Published var isEnhancing = false

    var onTranscriptionFinished: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private var inputSampleRate: Double = 16000
    private let modelManager: MLXModelManager
    private let targetSampleRate = 16000

    init(modelManager: MLXModelManager) {
        self.modelManager = modelManager
    }

    func requestPermissions() async -> Bool {
        let micStatus = await AVCaptureDevice.requestAccess(for: .audio)
        return micStatus
    }

    func startRecording() {
        guard !isRecording else { return }

        resetTransientState()

        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputSampleRate = recordingFormat.sampleRate

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self else { return }

                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                    self.audioBuffer.append(contentsOf: samples)

                    if frameLength > 0 {
                        var rms: Float = 0
                        for i in 0..<frameLength {
                            rms += channelData[i] * channelData[i]
                        }
                        rms = sqrt(rms / Float(frameLength))
                        let normalized = min(rms * 20, 1.0)
                        Task { @MainActor [weak self] in
                            self?.audioLevel = normalized
                        }
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            print("MLXTranscriber: Failed to start recording: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        stopAudioEngine()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        let capturedAudio = audioBuffer
        audioBuffer = []

        guard !capturedAudio.isEmpty else {
            print("[Voxt] STT skipped: no captured audio samples")
            onTranscriptionFinished?("")
            return
        }

        let seconds = inputSampleRate > 0 ? Double(capturedAudio.count) / inputSampleRate : 0
        print("[Voxt] STT captured: samples=\(capturedAudio.count), sampleRate=\(Int(inputSampleRate)), duration=\(String(format: "%.2f", seconds))s")

        Task {
            await transcribeAudio(capturedAudio, sampleRate: inputSampleRate)
        }
    }

    private func transcribeAudio(_ samples: [Float], sampleRate: Double) async {
        do {
            let model = try await modelManager.loadModel()
            let audioSamples = try prepareInputSamples(samples, sampleRate: sampleRate)
            let (streamedText, finalOutput, emittedTokens) = try await runStreamingInference(model: model, audioSamples: audioSamples)
            print("[Voxt] STT inference done (stream), tokens=\(emittedTokens)")

            let text = (finalOutput?.text ?? streamedText).trimmingCharacters(in: .whitespacesAndNewlines)
            let promptTokens = finalOutput?.promptTokens ?? 0
            let generationTokens = finalOutput?.generationTokens ?? emittedTokens
            let language = finalOutput?.language ?? "nil"
            let snippet = String(text.prefix(80))
            print("[Voxt] STT output: chars=\(text.count), promptTokens=\(promptTokens), generationTokens=\(generationTokens), language=\(language), snippet=\(snippet)")
            transcribedText = text
            onTranscriptionFinished?(text)
        } catch {
            print("MLXTranscriber: Transcription failed: \(error)")
            onTranscriptionFinished?("")
        }
    }

    private func resetTransientState() {
        audioBuffer = []
        transcribedText = ""
        audioLevel = 0
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func prepareInputSamples(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        if abs(sampleRate - Double(targetSampleRate)) > 1.0 {
            let resampled = try resampleAudio(samples, from: Int(sampleRate), to: targetSampleRate)
            print("[Voxt] STT resampled: \(samples.count) -> \(resampled.count) samples (\(Int(sampleRate))Hz -> \(targetSampleRate)Hz)")
            return resampled
        }

        print("[Voxt] STT resample skipped: already near \(targetSampleRate)Hz")
        return samples
    }

    private func runStreamingInference(
        model: any STTGenerationModel,
        audioSamples: [Float]
    ) async throws -> (streamedText: String, finalOutput: STTOutput?, emittedTokens: Int) {
        print("[Voxt] STT inference start (stream)")
        let audioArray = MLXArray(audioSamples)
        var streamedText = ""
        var finalOutput: STTOutput?
        var emittedTokens = 0

        for try await event in model.generateStream(audio: audioArray) {
            switch event {
            case .token(let token):
                emittedTokens += 1
                streamedText += token
                transcribedText = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            case .info:
                break
            case .result(let output):
                finalOutput = output
            }
        }

        return (streamedText, finalOutput, emittedTokens)
    }
}

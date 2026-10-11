import FluidAudio
import Foundation

/// A single transcript segment in the shape Speakr's `asr_endpoint` connector
/// expects (`src/services/transcription/connectors/asr_endpoint.py`):
/// `{"start": ..., "end": ..., "speaker": "SPEAKER_00" | null, "text": "..."}`.
struct AsrSegment {
    let start: Double
    let end: Double
    let speaker: String?
    let text: String
}

struct AsrOutput {
    let text: String
    let language: String?
    let segments: [AsrSegment]
}

/// Loads Parakeet (ASR) and the offline pyannote-CoreML diarization pipeline
/// once at startup, then serves both from memory for every request. FluidAudio
/// runs inference on the Apple Neural Engine, not the GPU/MPS, so this can run
/// alongside a GPU-resident chat model (e.g. Ollama) without contention.
actor TranscriptionEngine {
    private let asrManager: AsrManager
    // OfflineDiarizerManager is a plain class, not an actor; its `process`
    // method runs on a @concurrent executor. Every call to it is already
    // serialized through this actor's own isolation (no other code ever
    // touches it), so it's safe to opt it out of the compiler's stricter
    // region-isolation check for sending actor-isolated state across executors.
    private nonisolated(unsafe) let diarizerManager: OfflineDiarizerManager

    private init(asrManager: AsrManager, diarizerManager: OfflineDiarizerManager) {
        self.asrManager = asrManager
        self.diarizerManager = diarizerManager
    }

    static func bootstrap() async throws -> TranscriptionEngine {
        // .ultra is FluidAudio's own recommended successor to .v3 (same speed,
        // better accuracy, same 25-language coverage) - override via env if
        // the pinned .v3 ever needs to move.
        let versionName = ProcessInfo.processInfo.environment["PARAKEET_VERSION"] ?? "v3"
        let version: AsrModelVersion = (versionName == "ultra") ? .ultra : .v3

        print("Loading Parakeet (\(versionName))...")
        let asrModels = try await AsrModels.downloadAndLoad(version: version)
        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(asrModels)

        print("Loading offline speaker-diarization pipeline (pyannote Community-1 CoreML port)...")
        let diarizerManager = OfflineDiarizerManager(config: .default)
        try await diarizerManager.prepareModels()

        print("Models loaded.")
        return TranscriptionEngine(asrManager: asrManager, diarizerManager: diarizerManager)
    }

    /// Transcribe one audio file, optionally diarized. `minSpeakers`/
    /// `maxSpeakers` are accepted (Speakr's connector always sends them when
    /// set) but not enforced: the offline pipeline's VBx clustering is
    /// threshold-based, not fixed-K, so there's no clean way to honor an exact
    /// speaker count here.
    func process(fileURL: URL, diarize: Bool) async throws -> AsrOutput {
        // Fresh state per request: this is one-shot batch transcription, not
        // a streaming session, so there's no decoder context to carry over.
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(fileURL, decoderState: &decoderState)
        let wordTimings = buildWordTimings(from: result.tokenTimings ?? [])

        guard diarize, !wordTimings.isEmpty else {
            return AsrOutput(
                text: result.text,
                language: nil,
                segments: [
                    AsrSegment(start: 0, end: result.duration, speaker: nil, text: result.text)
                ]
            )
        }

        let samples = try AudioConverter().resampleAudioFile(path: fileURL.path)
        let diarization = try await diarizerManager.process(audio: samples)

        let segments = mergeWordsWithSpeakers(
            words: wordTimings,
            speakerTurns: diarization.segments
        )
        return AsrOutput(text: result.text, language: nil, segments: segments)
    }
}

import Vapor
import Foundation

/// Matches the multipart field `asr_endpoint.py` sends: `audio_file`.
struct AsrUploadForm: Content {
    var audio_file: File
}

struct AsrSegmentDTO: Content {
    let start: Double
    let end: Double
    let speaker: String?
    let text: String
}

struct AsrResponseDTO: Content {
    let text: String
    let language: String?
    let segments: [AsrSegmentDTO]
}

struct ModelsResponseDTO: Content {
    struct Model: Content {
        let id: String
        let owned_by: String
    }
    let data: [Model]
}

func routes(_ app: Application, engine: TranscriptionEngine) throws {
    // Speakr's health_check() tries /health then / - either just needs <500.
    app.get { req async -> String in "ok" }
    app.get("health") { req async -> String in "ok" }

    // Probed by Speakr's list_models() for the admin model dropdown.
    app.get("v1", "models") { req async -> ModelsResponseDTO in
        let modelId = ProcessInfo.processInfo.environment["PARAKEET_VERSION"] == "ultra"
            ? "parakeet-ultra" : "parakeet-tdt-0.6b-v3"
        return ModelsResponseDTO(data: [.init(id: modelId, owned_by: "fluidaudio")])
    }

    // The contract Speakr's asr_endpoint connector speaks:
    // POST /asr?encode=true&task=transcribe&output=json&diarize=&enable_diarization=&...
    // multipart field "audio_file" -> {"text", "language", "segments": [{start,end,speaker,text}]}
    app.on(.POST, "asr", body: .collect(maxSize: "2gb")) { req async throws -> AsrResponseDTO in
        let form = try req.content.decode(AsrUploadForm.self)

        // whisper-asr-webservice calls it 'diarize', WhisperX calls it
        // 'enable_diarization' - asr_endpoint.py sends both, so honor whichever is set.
        let diarize = boolQuery(req, "diarize") ?? boolQuery(req, "enable_diarization") ?? true

        let tempDir = FileManager.default.temporaryDirectory
        let ext = form.audio_file.filename.split(separator: ".").last.map { ".\($0)" } ?? ".wav"
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ext)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let data = form.audio_file.data.getData(at: 0, length: form.audio_file.data.readableBytes) else {
            throw Abort(.badRequest, reason: "Empty audio_file upload")
        }
        try data.write(to: tempURL)

        let output = try await engine.process(fileURL: tempURL, diarize: diarize)

        return AsrResponseDTO(
            text: output.text,
            language: output.language,
            segments: output.segments.map {
                AsrSegmentDTO(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text)
            }
        )
    }
}

private func boolQuery(_ req: Request, _ key: String) -> Bool? {
    guard let raw = try? req.query.get(String.self, at: key) else { return nil }
    return ["true", "1", "yes"].contains(raw.lowercased())
}

import Vapor
import Foundation

@main
struct Entrypoint {
    static func main() async throws {
        let engine = try await TranscriptionEngine.bootstrap()

        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)

        app.http.server.configuration.hostname = ProcessInfo.processInfo.environment["HOST"] ?? "0.0.0.0"
        app.http.server.configuration.port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "") ?? 9099

        try routes(app, engine: engine)
        try await app.execute()
    }
}

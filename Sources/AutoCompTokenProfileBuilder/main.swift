import AutoCompCore
import AutoCompLlamaRuntime
import Foundation

@main
enum AutoCompTokenProfileBuilder {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2 || arguments.count == 3 else {
                throw BuilderError.usage
            }
            let modelURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
            let outputURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let family = arguments.count == 3 ? arguments[2] : modelURL.deletingPathExtension().lastPathComponent
            let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: true)
            try await backend.loadModel(configuration: LocalLlamaConfiguration(
                modelPath: modelURL.path,
                modelName: family,
                maxRAMBytes: UInt64.max
            ))
            let profile = try await backend.experimentalTokenProfile(modelFamily: family)
            await backend.shutdown()
            let encoded = try AutoCompTokenProfileCodec.encode(profile)
            try encoded.write(to: outputURL, options: .atomic)
            print("Wrote \(profile.vocabularySize) tokens to \(outputURL.path)")
            print("Tokenizer digest: \(profile.tokenizerDigest.map { String(format: "%02x", $0) }.joined())")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
}

private enum BuilderError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: AutoCompTokenProfileBuilder <model.gguf> <output.actkp> [model-family]"
    }
}

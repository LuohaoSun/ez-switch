import Foundation
import Testing
@testable import EZSwitch

@Suite("Responses translator streaming")
struct ResponseTranslatorStreamTests {
    private var executable: URL { BridgeTestExecutable.url }
    @Test(.enabled(if: BridgeTestExecutable.available, "Run ./build-translator.sh to enable bridge streaming tests"))
    func streamSurvivesSplitEventsAndPreservesSingleCompletion() async throws {
        let translator = try ResponseTranslator(executable: executable)
        defer { translator.stop() }
        _ = try await translator.prepare(Data(#"{"model":"main","input":"Hello","stream":true}"#.utf8), model: "real")
        let events = """
        data: {"id":"chatcmpl_test","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

        data: {"id":"chatcmpl_test","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let bytes = Array((events + "\n").utf8)
        var result = Data()
        for start in stride(from: 0, to: bytes.count, by: 7) {
            let end = min(start + 7, bytes.count)
            for block in try await translator.consume(Data(bytes[start..<end])) { result.append(block) }
        }
        for block in try await translator.finish() { result.append(block) }
        let output = try #require(String(data: result, encoding: .utf8))
        #expect(output.contains("event: response.output_text.delta"))
        #expect(output.components(separatedBy: "event: response.completed").count == 2)
    }

    @Test(.enabled(if: BridgeTestExecutable.available, "Run ./build-translator.sh to enable bridge streaming tests"))
    func truncatedChatStreamDoesNotComplete() async throws {
        let translator = try ResponseTranslator(executable: executable)
        defer { translator.stop() }
        _ = try await translator.prepare(Data(#"{"model":"main","input":"Hello","stream":true}"#.utf8), model: "real")
        let data = Data(#"data: {"id":"chatcmpl_test","object":"chat.completion.chunk","created":1,"model":"real","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#.utf8)
        _ = try await translator.consume(data + Data("\n\n".utf8))
        do {
            _ = try await translator.finish()
            Issue.record("truncated stream was accepted")
        } catch let error as ResponseTranslationError {
            #expect(error.description.contains("without [DONE]"))
        }
    }
    @Test
    func cancellationStopsAStalledHelper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranslatorCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper")
        try Data("#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 60\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let translator = try ResponseTranslator(executable: helper)
        defer { translator.stop() }
        let task = Task {
            try await translator.prepare(Data(#"{"model":"main","input":"Hello"}"#.utf8), model: "real")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled helper returned a successful body")
        } catch { }
    }

}

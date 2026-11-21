import KeyshiftCore
@testable import KeyshiftSystem
import XCTest

final class EventTapIntegrationTests: XCTestCase {
    func testSelfTestReportsStoppedBackendWithoutPermissions() {
        let backend = EventTapBackend(engine: ProbeEngine(), context: ContextProvider(), executor: ActionExecutor())
        XCTAssertEqual(SelfTest.run(backend: backend).outcome, .backendNotRunning)
    }

    func testSelfTestObservesRewriteAndTaggedReplacement() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEYSHIFT_INTEGRATION"] == "1")
        try XCTSkipUnless(Permissions.accessibility(), "Accessibility permission is required for live Quartz tests.")

        let backend = EventTapBackend(engine: ProbeEngine(), context: ContextProvider(), executor: ActionExecutor())
        backend.reload(Config(selectedProfile: "rewrite"))
        try backend.start()
        defer { backend.stop() }

        let input = KeyCombo(KeyCode(80), .control) // Ctrl+F19 avoids a frontmost-app dependency.
        let expected = KeyCombo(input.key, .command)
        let rewrite = SelfTest.run(backend: backend, input: input, expected: expected)
        XCTAssertEqual(rewrite.outcome, .passed, "\(rewrite.observed)")

        backend.reload(Config(selectedProfile: "replace"))
        let replacement = SelfTest.run(backend: backend, input: input, expected: expected)
        XCTAssertEqual(replacement.outcome, .passed, "\(replacement.observed)")

        backend.setPaused(true)
        let paused = SelfTest.run(backend: backend, input: input, expected: expected, timeout: 0.25)
        XCTAssertEqual(paused.outcome, .mismatch, "\(paused.observed)")
        XCTAssertTrue(paused.observed.allSatisfy { $0.modifiers.contains(.control) })

        backend.setPaused(false)
        let resumed = SelfTest.run(backend: backend, input: input, expected: expected)
        XCTAssertEqual(resumed.outcome, .passed, "\(resumed.observed)")
        backend.stop()
        XCTAssertFalse(backend.isRunning)
    }

    private final class ProbeEngine: RemapEngine {
        private var shouldReplace = false

        func load(config: Config) { shouldReplace = config.selectedProfile == "replace" }
        func reset() {}

        func handle(_ event: InputEvent, context: EngineContext) -> Decision {
            // Matching the posted output too catches a replacement fed back into the engine.
            guard event.key == KeyCode(80) else { return .pass }
            let output: OutputEvent
            switch event.kind {
            case .keyDown: output = .keyDown(event.key, .command, isRepeat: event.isRepeat)
            case .keyUp: output = .keyUp(event.key, .command)
            default: return .pass
            }
            return shouldReplace ? Decision(.replace, emit: [output]) : Decision(.rewrite(output))
        }
    }
}

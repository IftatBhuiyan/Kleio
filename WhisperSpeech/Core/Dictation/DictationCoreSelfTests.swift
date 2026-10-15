#if DEBUG
import Foundation

enum DictationCoreSelfTests {
    private static var hasRun = false

    static func runIfNeeded() {
        guard !hasRun else { return }
        hasRun = true

        testTranscriptAssembler()
        testStatusReducerTransitions()
        testConnectionRefreshPolicy()
        testTransportFailurePolicy()
        testRealtimeOutgoingMessageDisposition()
        testRealtimeLivenessPolicy()
        testMacAudioFocusStateMachine()
        testBackendTransportSecurity()
    }

    private static func testBackendTransportSecurity() {
        for endpoint in ["http://example.org", "ws://example.org", "wss://user:password@example.org", "wss:///missing-host"] {
            do {
                try RealtimeWebSocketClient().configure(backendURLString: endpoint, authToken: "")
                expect(false, "unsafe backend URL accepted: \(endpoint)")
            } catch { /* Expected: credentials and audio must use secure transport. */ }
        }
        for endpoint in ["wss://example.org", "ws://127.0.0.1:8080", "ws://localhost:8080"] {
            do { try RealtimeWebSocketClient().configure(backendURLString: endpoint, authToken: "") }
            catch { expect(false, "valid backend URL rejected: \(endpoint)") }
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String
    ) {
        guard condition() else {
            let failure = "DictationCoreSelfTests failed: \(message())"
            print(failure)
            // Fail loudly in DEBUG so core-pipeline regressions can't scroll
            // by as a single console line (MAC-OPEN-12).
            assertionFailure(failure)
            return
        }
    }

    private static func testTranscriptAssembler() {
        var assembler = TranscriptAssembler()
        expect(assembler.snapshot().bestText.isEmpty, "transcript assembler should start empty")

        let partial = assembler.applyPartial("send the email to John")
        expect(partial.bestText == "send the email to John", "partial transcript should become bestText")
        expect(partial.finalText.isEmpty, "partial transcript should not set finalText")

        let final = assembler.applyFinal("Send the email to Sarah.")
        expect(final.bestText == "Send the email to Sarah.", "final transcript should become bestText")
        expect(final.finalText == "Send the email to Sarah.", "final transcript should populate finalText")
    }

    private static func testStatusReducerTransitions() {
        var state = DictationStatus.idle
        state = DictationStatusReducer.reduce(from: state, event: .startListening)
        expect(state == .listening, "startListening should move the reducer into listening")

        state = DictationStatusReducer.reduce(from: state, event: .stopListening)
        expect(state == .processing, "stopListening should move the reducer into processing")

        state = DictationStatusReducer.reduce(from: state, event: .finalTextReceived)
        expect(state == .idle, "finalTextReceived should return the reducer to idle")

        state = DictationStatusReducer.reduce(from: .processing, event: .noSpeechDetected)
        expect(state == .idle, "noSpeechDetected should return processing back to idle")

        state = DictationStatusReducer.reduce(from: state, event: .failure("network"))
        if case .error(let message) = state {
            expect(message == "network", "failure should preserve the reducer error message")
        } else {
            print("DictationCoreSelfTests failed: expected an error state after failure")
        }
    }

    private static func testConnectionRefreshPolicy() {
        expect(
            ConnectionRefreshPolicy.shouldDefer(for: .listening),
            "listening should defer websocket refreshes"
        )
        expect(
            ConnectionRefreshPolicy.shouldDefer(for: .processing),
            "processing should defer websocket refreshes"
        )
        expect(
            ConnectionRefreshPolicy.shouldDefer(for: .idle) == false,
            "idle should allow websocket refreshes immediately"
        )
        expect(
            ConnectionRefreshPolicy.shouldDefer(for: .error("network")) == false,
            "error should allow websocket refreshes immediately"
        )
    }

    private static func testTransportFailurePolicy() {
        expect(
            DictationTransportFailurePolicy.shouldSurfaceAsDictationError(
                status: .idle,
                isCapturing: false,
                streamingSessionState: "idle"
            ) == false,
            "idle warm websocket failures should not poison dictation state"
        )
        expect(
            DictationTransportFailurePolicy.shouldSurfaceAsDictationError(
                status: .listening,
                isCapturing: false,
                streamingSessionState: "live"
            ),
            "listening websocket failures should surface as dictation errors"
        )
        expect(
            DictationTransportFailurePolicy.shouldSurfaceAsDictationError(
                status: .processing,
                isCapturing: false,
                streamingSessionState: "finalizing"
            ),
            "finalizing websocket failures should surface as dictation errors"
        )
        expect(
            DictationTransportFailurePolicy.shouldSurfaceAsDictationError(
                status: .idle,
                isCapturing: true,
                streamingSessionState: "idle"
            ),
            "capture failures should surface even if the transport snapshot is idle"
        )
        expect(
            DictationTransportFailurePolicy.shouldSurfaceAsDictationError(
                status: .error("previous"),
                isCapturing: false,
                streamingSessionState: "idle"
            ) == false,
            "idle reconnect failures must not re-raise an existing error"
        )
    }

    private static func testRealtimeOutgoingMessageDisposition() {
        expect(
            realtimeOutgoingMessageDisposition(
                for: .audioChunk,
                awaitingSessionStartAcknowledgement: true,
                dropStreamingMessagesUntilNextSessionStart: false
            ) == .bufferUntilSessionStartAcknowledgement,
            "audio should buffer until session_start acknowledgement arrives"
        )
        expect(
            realtimeOutgoingMessageDisposition(
                for: .sessionEnd,
                awaitingSessionStartAcknowledgement: true,
                dropStreamingMessagesUntilNextSessionStart: false
            ) == .bufferUntilSessionStartAcknowledgement,
            "session_end should buffer until session_start acknowledgement arrives"
        )
        expect(
            realtimeOutgoingMessageDisposition(
                for: .audioChunk,
                awaitingSessionStartAcknowledgement: false,
                dropStreamingMessagesUntilNextSessionStart: true
            ) == .drop,
            "stale audio should be dropped after an interrupted live session"
        )
        expect(
            realtimeOutgoingMessageDisposition(
                for: .sessionStart,
                awaitingSessionStartAcknowledgement: false,
                dropStreamingMessagesUntilNextSessionStart: true
            ) == .sendNow,
            "a fresh session_start should still be allowed after an interruption"
        )
    }

    private static func testRealtimeLivenessPolicy() {
        expect(
            RealtimeLivenessPolicy.shouldRecycle(now: 100, lastInboundAt: 100, pingInterval: 15) == false,
            "a fresh connection should not be recycled"
        )
        expect(
            RealtimeLivenessPolicy.shouldRecycle(now: 129, lastInboundAt: 100, pingInterval: 15) == false,
            "under two intervals of silence should not recycle"
        )
        expect(
            RealtimeLivenessPolicy.shouldRecycle(now: 131, lastInboundAt: 100, pingInterval: 15),
            "more than two intervals of inbound silence should recycle the connection"
        )
    }

    private static func testMacAudioFocusStateMachine() {
        let armingState = MacDictationAudioFocusStateMachine.startRequested(duckingEnabled: true)
        expect(armingState == .arming, "ducking-enabled capture should start in arming")

        let disabledState = MacDictationAudioFocusStateMachine.startRequested(duckingEnabled: false)
        expect(disabledState == .disabled, "ducking-disabled capture should stay disabled")

        let degradedState = MacDictationAudioFocusStateMachine.duckingSetupFailed()
        expect(
            degradedState == .degraded(.duckingUnavailable),
            "ducking setup failure should mark the session as degraded"
        )

        let activeState = MacDictationAudioFocusStateMachine.captureStarted(
            from: armingState,
            duckingEnabled: true
        )
        expect(activeState == .active, "successful arming should become active after capture starts")

        let preservedDegradedState = MacDictationAudioFocusStateMachine.captureStarted(
            from: degradedState,
            duckingEnabled: true
        )
        expect(
            preservedDegradedState == .degraded(.duckingUnavailable),
            "successful capture should preserve degraded ducking state"
        )

        let blockedState = MacDictationAudioFocusStateMachine.captureFailed(issue: .microphoneBusy)
        expect(
            blockedState == .blocked(.microphoneBusy),
            "capture failure should move the focus state into blocked"
        )

        let releasedState = MacDictationAudioFocusStateMachine.stop()
        expect(releasedState == .disabled, "stop should release mac audio focus state")
    }
}
#endif

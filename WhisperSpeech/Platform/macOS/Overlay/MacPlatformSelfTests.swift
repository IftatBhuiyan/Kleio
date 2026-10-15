#if DEBUG
import CoreGraphics
import Foundation

enum MacPlatformSelfTests {
    private static var hasRun = false

    static func runIfNeeded() {
        guard !hasRun else { return }
        hasRun = true

        testDictationPillPromptText()
        testDictationPillPlacement()
        testDictationPillRecentsCardLayout()
        testDictationPillFocusDisplayActivity()
        testSmartShortcutDoubleTapToggle()
        testSmartShortcutHoldToTalk()
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String
    ) {
        guard condition() else {
            let failure = "MacPlatformSelfTests failed: \(message())"
            print(failure)
            // Fail loudly in DEBUG so reducer/layout regressions can't scroll
            // by as a single console line (MAC-OPEN-12).
            assertionFailure(failure)
            return
        }
    }

    private static func testDictationPillPromptText() {
        let state = MacDictationPillState(
            activity: .idle,
            liveInputLevel: 0,
            shortcutTokens: ["fn"]
        )
        expect(
            state.promptText == "Click, hold, or double-tap fn to start dictating",
            "unexpected dictation pill prompt text"
        )
    }

    private static func testDictationPillPlacement() {
        let visibleFrame = CGRect(x: 120, y: 40, width: 1600, height: 900)
        let origin = MacDictationPillLayout.panelOrigin(in: visibleFrame)

        expect(
            origin.x == visibleFrame.midX - (MacDictationPillLayout.panelSize.width / 2),
            "unexpected dictation pill horizontal placement"
        )
        expect(
            origin.y == visibleFrame.minY + MacDictationPillLayout.bottomMargin,
            "unexpected dictation pill vertical placement"
        )
    }

    private static func testDictationPillRecentsCardLayout() {
        // The panel was enlarged (from 340x142) to make room for the hover-expanded
        // recents card above the pill. Lock the exact size down so a future layout
        // tweak can't silently shrink the card's available space.
        expect(
            MacDictationPillLayout.panelSize == CGSize(width: 340, height: 290),
            "unexpected dictation pill panel size after recents-card enlargement"
        )

        // Growing the panel's height must not move the pill: panelOrigin() pins the
        // panel's bottom edge, and NSPanel/NSWindow frames are bottom-left-origin in
        // AppKit screen space, so the extra height only extends the panel upward.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = MacDictationPillLayout.panelOrigin(in: visibleFrame)
        expect(
            origin.y == visibleFrame.minY + MacDictationPillLayout.bottomMargin,
            "enlarging the panel for the recents card should not move the pill's anchored bottom edge"
        )

        expect(
            MacDictationPillLayout.recentsHoverZoneSize == CGSize(width: 120, height: 24),
            "unexpected recents-card idle hover-zone size"
        )
    }

    private static func testDictationPillFocusDisplayActivity() {
        expect(
            macDictationPillDisplayActivity(for: .listening, isFocusedScreen: true) == .listening,
            "focused screen should preserve the live dictation activity"
        )
        expect(
            macDictationPillDisplayActivity(for: .processing, isFocusedScreen: false) == .idle,
            "non-focused screens should render the calm idle pill"
        )
    }

    private static func testSmartShortcutDoubleTapToggle() {
        var state = SmartDictationShortcutState()
        let firstPress = state.handlePress(at: 0, doubleTapWindow: 0.32)
        expect(
            firstPress == [.cancelHoldActivation, .scheduleHoldActivation],
            "first shortcut press should arm hold activation"
        )

        let firstRelease = state.handleRelease(at: 0.08)
        expect(
            firstRelease == [.cancelHoldActivation],
            "first shortcut release should only cancel pending hold activation"
        )

        let secondPress = state.handlePress(at: 0.18, doubleTapWindow: 0.32)
        expect(
            secondPress == [.cancelHoldActivation, .startDictation],
            "second shortcut press inside the double-tap window should start toggled dictation"
        )
        expect(
            state.sessionMode == .toggled,
            "double-tap should leave the shortcut reducer in toggled mode"
        )

        let secondRelease = state.handleRelease(at: 0.22)
        expect(
            secondRelease == [.cancelHoldActivation],
            "releasing after the latch press should keep dictation toggled on"
        )

        let stopPress = state.handlePress(at: 0.42, doubleTapWindow: 0.32)
        expect(
            stopPress == [.cancelHoldActivation, .stopDictation],
            "pressing while toggled should stop dictation immediately"
        )
        expect(
            state.sessionMode == .idle,
            "stop press should return the shortcut reducer to idle"
        )

        let stopRelease = state.handleRelease(at: 0.46)
        expect(
            stopRelease == [.cancelHoldActivation],
            "stop release should only clear any pending hold activation state"
        )
    }

    private static func testSmartShortcutHoldToTalk() {
        var state = SmartDictationShortcutState()
        let firstPress = state.handlePress(at: 0, doubleTapWindow: 0.32)
        expect(
            firstPress == [.cancelHoldActivation, .scheduleHoldActivation],
            "hold-to-talk press should arm hold activation"
        )

        let holdActivation = state.handleHoldActivationTimer()
        expect(
            holdActivation == [.startDictation],
            "hold activation timer should start dictation"
        )
        expect(
            state.sessionMode == .holding,
            "hold activation should move the reducer into holding mode"
        )

        let release = state.handleRelease(at: 0.5)
        expect(
            release == [.cancelHoldActivation, .stopDictation],
            "releasing after hold-to-talk should stop dictation"
        )
        expect(
            state.sessionMode == .idle,
            "hold-to-talk release should return the reducer to idle"
        )
    }
}
#endif

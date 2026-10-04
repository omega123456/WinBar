import Testing
@testable import WinBar

/// Runs the `--self-test` logic checks under `swift test` too, so coverage counts them.
@MainActor @Test func selfTest() { #expect(SelfTest.run()) }

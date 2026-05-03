import Testing
@testable import HermesDesktop

struct HermesChatInvocationTests {
    @Test
    func resumeInvocationUsesQuietNonInteractiveChat() {
        let invocation = HermesChatInvocation(
            sessionID: "session-123",
            prompt: "Continue from the previous result"
        )

        #expect(invocation.arguments == [
            "--resume",
            "session-123",
            "chat",
            "--quiet",
            "--query",
            "Continue from the previous result"
        ])
    }

    @Test
    func promptIsPassedAsSingleArgument() {
        let prompt = """
        summarize this diff && rm -rf nope
        "quoted" text stays payload, not shell
        """
        let invocation = HermesChatInvocation(sessionID: "abc", prompt: prompt)

        #expect(invocation.arguments.last == prompt)
        #expect(invocation.arguments.count == 6)
    }

    @Test
    func newSessionInvocationOmitsResumeArgument() {
        let invocation = HermesChatInvocation(sessionID: nil, prompt: "Start fresh")

        #expect(invocation.arguments == [
            "chat",
            "--quiet",
            "--query",
            "Start fresh"
        ])
    }

    @Test
    func autoApproveAddsYoloBeforeChatCommand() {
        let invocation = HermesChatInvocation(
            sessionID: "session-123",
            prompt: "Inspect the repo",
            autoApproveCommands: true
        )

        #expect(invocation.arguments == [
            "--resume",
            "session-123",
            "--yolo",
            "chat",
            "--quiet",
            "--query",
            "Inspect the repo"
        ])
    }
}

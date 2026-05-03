import Foundation
import Testing
@testable import HermesDesktop

struct SessionMessageMetadataTests {
    @Test
    func displayMetadataHidesDuplicateReasoningContent() throws {
        let message = try decodeMessage("""
        {
          "id": "1",
          "role": "assistant",
          "content": "hello",
          "metadata": {
            "finish_reason": "stop",
            "reasoning": "Same thought.",
            "reasoning_content": "Same thought."
          }
        }
        """)

        #expect(message.displayMetadata?["reasoning"] == .string("Same thought."))
        #expect(message.displayMetadata?["reasoning_content"] == nil)
        #expect(message.displayMetadata?["finish_reason"] == .string("stop"))
    }

    @Test
    func displayMetadataKeepsReasoningContentWhenDistinct() throws {
        let message = try decodeMessage("""
        {
          "id": "1",
          "role": "assistant",
          "content": "hello",
          "metadata": {
            "reasoning": "Short thought.",
            "reasoning_content": "Expanded reasoning content."
          }
        }
        """)

        #expect(message.displayMetadata?["reasoning"] == .string("Short thought."))
        #expect(message.displayMetadata?["reasoning_content"] == .string("Expanded reasoning content."))
    }

    private func decodeMessage(_ json: String) throws -> SessionMessage {
        try JSONDecoder().decode(SessionMessage.self, from: Data(json.utf8))
    }
}

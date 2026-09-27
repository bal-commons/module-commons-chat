// Streamed text of STREAMING messages, held in memory until the message completes.
isolated class Buffers {
    private final map<string> texts = {};

    isolated function append(string conversationId, string messageId, string text) {
        lock {
            string key = conversationId + "/" + messageId;
            self.texts[key] = (self.texts[key] ?: "") + text;
        }
    }

    isolated function get(string conversationId, string messageId) returns string? {
        lock {
            return self.texts[conversationId + "/" + messageId];
        }
    }

    isolated function reset(string conversationId, string messageId) {
        lock {
            _ = self.texts.removeIfHasKey(conversationId + "/" + messageId);
        }
    }
}

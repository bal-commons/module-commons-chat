import ballerina/http;
import ballerina/url;

# Client for the chat service.
public isolated client class Client {
    private final http:Client http;
    private final map<string> & readonly headers;

    # Creates a client.
    #
    # + serviceUrl - Base URL including the base path, e.g. `http://localhost:9101/chat/v1`
    # + config - HTTP client settings, including `auth` for OAuth2 client credentials
    # + headers - Sent on every request, e.g. `x-api-key`, or `x-user-id` in trusted-header mode
    # + return - An error if the client cannot be created
    public isolated function init(string serviceUrl, http:ClientConfiguration config = {}, map<string> headers = {})
            returns error? {
        self.http = check new (serviceUrl, config);
        self.headers = headers.cloneReadOnly();
    }

    # Creates a conversation; a repeated correlation ID returns the existing one.
    #
    # + conversation - The conversation
    # + return - The conversation, or an error
    remote isolated function createConversation(NewConversation conversation) returns Conversation|error {
        return self.http->post("/conversations", conversation, self.headers);
    }

    # Gets a conversation.
    #
    # + conversationId - Conversation ID
    # + return - The conversation, or an error (404 when the caller may not read it)
    remote isolated function getConversation(string conversationId) returns Conversation|error {
        return self.http->get(check conversationPath(conversationId), self.headers);
    }

    # Lists the caller's conversations, most recently active first.
    #
    # + options - Filters and paging
    # + return - One page, or an error
    remote isolated function listConversations(*ConversationListOptions options) returns ConversationPage|error {
        return self.http->get("/conversations" + check queryString(options), self.headers);
    }

    # Lists any conversations. Requires the admin scope.
    #
    # + options - Filters and paging
    # + return - One page, or an error
    remote isolated function adminListConversations(*AdminConversationListOptions options)
            returns ConversationPage|error {
        return self.http->get("/admin/conversations" + check queryString(options), self.headers);
    }

    # Finds the conversation with a correlation ID. Requires the admin scope.
    #
    # + correlationId - Correlation ID
    # + return - The conversation, `()` if there is none, or an error
    remote isolated function findByCorrelation(string correlationId) returns Conversation?|error {
        ConversationPage page = check self->adminListConversations(correlationId = correlationId, 'limit = 1);
        return page.items.length() == 0 ? () : page.items[0];
    }

    # Sends a message.
    #
    # + conversationId - Conversation ID
    # + message - The message
    # + return - The stored message (the original one when `id` repeats), or an error
    remote isolated function sendMessage(string conversationId, NewMessage message) returns Message|error {
        return self.http->post(check conversationPath(conversationId) + "/messages", message, self.headers);
    }

    # Sends a text message.
    #
    # + conversationId - Conversation ID
    # + text - The text
    # + senderId - Agent participant to post as
    # + id - Idempotency ID
    # + return - The stored message, or an error
    remote isolated function sendText(string conversationId, string text, string? senderId = (), string? id = ())
            returns Message|error {
        NewMessage message = {content: text};
        if senderId is string {
            message.senderId = senderId;
        }
        if id is string {
            message.id = id;
        }
        return self->sendMessage(conversationId, message);
    }

    # Answers a FORM message.
    #
    # + conversationId - Conversation ID
    # + formId - ID of the FORM message
    # + values - The answers
    # + senderId - Agent participant answering
    # + return - The FORM_RESPONSE message, or an error (409 when the form was already answered)
    remote isolated function submitForm(string conversationId, string formId, json values, string? senderId = ())
            returns Message|error {
        NewMessage message = {kind: FORM_RESPONSE, content: values, replyTo: formId};
        if senderId is string {
            message.senderId = senderId;
        }
        return self->sendMessage(conversationId, message);
    }

    # Opens a STREAMING text message. Opening the same ID again restarts it, so a retried activity overwrites
    # its earlier attempt instead of duplicating it.
    #
    # + conversationId - Conversation ID
    # + messageId - Message ID, e.g. derived from the workflow instance and step
    # + senderId - Agent participant streaming
    # + return - The message, or an error
    remote isolated function startStreaming(string conversationId, string messageId, string? senderId = ())
            returns Message|error {
        NewMessage message = {id: messageId, content: "", status: STREAMING};
        if senderId is string {
            message.senderId = senderId;
        }
        return self->sendMessage(conversationId, message);
    }

    # Appends text to a STREAMING message.
    #
    # + conversationId - Conversation ID
    # + messageId - Message ID
    # + text - The text
    # + senderId - Agent participant streaming
    # + return - An error if the message is not streaming or the call fails
    remote isolated function appendChunk(string conversationId, string messageId, string text,
            string? senderId = ()) returns error? {
        Chunk chunk = {text};
        if senderId is string {
            chunk.senderId = senderId;
        }
        http:Response response = check self.http->post(check messagePath(conversationId, messageId) + "/chunks",
            chunk, self.headers);
        return expectStatus(response, http:STATUS_ACCEPTED);
    }

    # Completes a STREAMING message.
    #
    # + conversationId - Conversation ID
    # + messageId - Message ID
    # + content - Final content; defaults to the streamed text
    # + senderId - Agent participant streaming
    # + return - The completed message, or an error
    remote isolated function completeMessage(string conversationId, string messageId, json content = (),
            string? senderId = ()) returns Message|error {
        Completion completion = {};
        if content !is () {
            completion.content = content;
        }
        if senderId is string {
            completion.senderId = senderId;
        }
        return self.http->post(check messagePath(conversationId, messageId) + "/complete", completion, self.headers);
    }

    # Gets one message.
    #
    # + conversationId - Conversation ID
    # + messageId - Message ID
    # + return - The message, or an error
    remote isolated function getMessage(string conversationId, string messageId) returns Message|error {
        return self.http->get(check messagePath(conversationId, messageId), self.headers);
    }

    # Reads history.
    #
    # + conversationId - Conversation ID
    # + options - Which slice to read
    # + return - Messages, oldest first, or an error
    remote isolated function history(string conversationId, *HistoryOptions options) returns MessagePage|error {
        return self.http->get(check conversationPath(conversationId) + "/messages" + check queryString(options),
            self.headers);
    }

    # Advances the caller's read position.
    #
    # + conversationId - Conversation ID
    # + seq - Last `seq` read
    # + return - The caller as a participant, or an error
    remote isolated function markRead(string conversationId, int seq) returns Participant|error {
        return self.http->put(check conversationPath(conversationId) + "/read", <ReadCursor>{seq}, self.headers);
    }

    # Signals that the caller, or an agent, is typing.
    #
    # + conversationId - Conversation ID
    # + senderId - Agent participant typing
    # + return - An error if the call fails
    remote isolated function typing(string conversationId, string? senderId = ()) returns error? {
        TypingSignal signal = {};
        if senderId is string {
            signal.senderId = senderId;
        }
        http:Response response = check self.http->post(check conversationPath(conversationId) + "/typing", signal,
            self.headers);
        return expectStatus(response, http:STATUS_ACCEPTED);
    }

    # Closes a conversation.
    #
    # + conversationId - Conversation ID
    # + reason - Why it is closed
    # + senderId - Agent participant closing it
    # + return - The closed conversation, or an error
    remote isolated function close(string conversationId, string? reason = (), string? senderId = ())
            returns Conversation|error {
        CloseRequest request = {};
        if reason is string {
            request.reason = reason;
        }
        if senderId is string {
            request.senderId = senderId;
        }
        return self.http->post(check conversationPath(conversationId) + "/close", request, self.headers);
    }

    # Registers a webhook for a participant. Requires the webhook scope.
    #
    # + webhook - The webhook
    # + return - The webhook with its secret, or an error
    remote isolated function registerWebhook(NewWebhook webhook) returns CreatedWebhook|error {
        return self.http->post("/webhooks", webhook, self.headers);
    }

    # Lists webhooks. Requires the webhook scope.
    #
    # + participantId - Only this participant's
    # + return - The webhooks, or an error
    remote isolated function listWebhooks(string? participantId = ()) returns Webhook[]|error {
        return self.http->get("/webhooks" + check queryString({"participantId": participantId}), self.headers);
    }

    # Lists a webhook's recent deliveries. Requires the webhook scope.
    #
    # + webhookId - Webhook ID
    # + return - Deliveries, newest first, or an error
    remote isolated function webhookDeliveries(string webhookId) returns WebhookDelivery[]|error {
        return self.http->get(string `/webhooks/${check url:encode(webhookId, "UTF-8")}/deliveries`, self.headers);
    }

    # Removes a webhook. Requires the webhook scope.
    #
    # + webhookId - Webhook ID
    # + return - An error if it does not exist or the call fails
    remote isolated function removeWebhook(string webhookId) returns error? {
        http:Response response = check self.http->delete(string `/webhooks/${check url:encode(webhookId, "UTF-8")}`,
            (), self.headers);
        return expectStatus(response, http:STATUS_NO_CONTENT);
    }

    # Issues a single-use ticket for opening the SSE stream from a browser.
    #
    # + return - The ticket, or an error
    remote isolated function streamTicket() returns StreamTicket|error {
        return self.http->post("/stream-ticket", (), self.headers);
    }

    # Opens the caller's SSE stream of all their conversations.
    #
    # + return - The event stream, or an error
    remote isolated function events() returns stream<http:SseEvent, error?>|error {
        return self.http->get("/stream", self.headers);
    }
}

isolated function conversationPath(string conversationId) returns string|error =>
    string `/conversations/${check url:encode(conversationId, "UTF-8")}`;

isolated function messagePath(string conversationId, string messageId) returns string|error =>
    string `${check conversationPath(conversationId)}/messages/${check url:encode(messageId, "UTF-8")}`;

isolated function expectStatus(http:Response response, int expected) returns error? {
    if response.statusCode != expected {
        return error(string `Request failed with status ${response.statusCode}: ${check response.getTextPayload()}`);
    }
}

isolated function queryString(record {} params) returns string|error {
    string[] parts = [];
    foreach [string, anydata] [key, value] in params.entries() {
        if value !is () {
            parts.push(string `${key}=${check url:encode(value.toString(), "UTF-8")}`);
        }
    }
    return parts.length() == 0 ? "" : "?" + string:'join("&", ...parts);
}

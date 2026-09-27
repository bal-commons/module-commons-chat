import commons/service_commons.webhook;

# Whether a participant is a person or an AI agent.
public enum ParticipantType {
    USER,
    AGENT
}

# Whether a conversation still accepts messages.
public enum ConversationStatus {
    OPEN,
    CLOSED
}

# Kinds of message. FORM carries a JSON Schema that the other party answers once with a FORM_RESPONSE.
public enum MessageKind {
    TEXT,
    SYSTEM,
    FORM,
    FORM_RESPONSE,
    ATTACHMENT_REF,
    EVENT
}

# Whether a message is still being streamed.
public enum MessageStatus {
    STREAMING,
    COMPLETE
}

# A participant to add to a new conversation.
public type NewParticipant record {|
    # Person or agent
    ParticipantType participantType = USER;
    # User ID, or an agent ID such as `agent:maintenance-triage`
    string participantId;
    # Name shown in the UI
    string displayName?;
|};

# A participant of a conversation.
public type Participant record {|
    # Person or agent
    ParticipantType participantType;
    # User or agent ID
    string participantId;
    # Name shown in the UI
    string displayName?;
    # Last message `seq` the participant has read
    int lastReadSeq;
|};

# A conversation to create.
public type NewConversation record {|
    # Ties the conversation to a case or workflow instance; a repeated one returns the existing conversation
    string correlationId?;
    # Title shown in the UI
    string title?;
    # The parties
    NewParticipant[] participants;
    # Structured data for the UI
    json metadata?;
|};

# A conversation.
public type Conversation record {|
    # ULID
    string id;
    # Correlation ID; the conversation ID when none was given
    string correlationId;
    # OPEN or CLOSED
    ConversationStatus status;
    # Title shown in the UI
    string title?;
    # The parties
    Participant[] participants;
    # `seq` of the latest message; 0 when empty
    int lastSeq;
    # Messages the caller has not read; present when the caller is a participant
    int unread?;
    # Who created it
    string createdBy;
    # RFC 3339 creation time
    string createdAt;
    # RFC 3339 time of the latest activity
    string updatedAt;
    # RFC 3339 close time
    string closedAt?;
    # Who closed it
    string closedBy?;
    # Why it was closed
    string closeReason?;
    # Structured data for the UI
    json metadata?;
|};

# One page of conversations, most recently active first.
public type ConversationPage record {|
    # Conversations on this page
    Conversation[] items;
    # Pass as `cursor` for the next page; absent on the last page
    string nextCursor?;
|};

# Filters for the caller's conversations.
public type ConversationListOptions record {|
    # Only this status
    ConversationStatus? status = ();
    # Only this correlation ID
    string? correlationId = ();
    # `nextCursor` of the previous page
    string? cursor = ();
    # Page size
    int? 'limit = ();
|};

# Filters for any conversation (admin).
public type AdminConversationListOptions record {|
    # Only conversations with this participant
    string? participantId = ();
    # Only this correlation ID
    string? correlationId = ();
    # Only this status
    ConversationStatus? status = ();
    # `nextCursor` of the previous page
    string? cursor = ();
    # Page size
    int? 'limit = ();
|};

# A message to send.
public type NewMessage record {|
    # Caller-chosen ID (letters, digits, `.`, `_`, `:`, `-`); reusing it makes a retried send idempotent
    string id?;
    # Kind
    MessageKind kind = TEXT;
    # TEXT and SYSTEM: a string. FORM: `{schema, ...}`. FORM_RESPONSE: the answers. ATTACHMENT_REF: `{name, ...}`.
    # EVENT: `{type, ...}`
    json content;
    # Message this one answers; required for FORM_RESPONSE
    string replyTo?;
    # STREAMING opens a TEXT message that chunks extend until it is completed
    MessageStatus status = COMPLETE;
    # Agent participant to post as; requires the post-as-agent scope
    string senderId?;
|};

# A message.
public type Message record {|
    # Message ID, unique within the conversation
    string id;
    # Conversation ID
    string conversationId;
    # Position in the conversation, from 1
    int seq;
    # Participant who sent it
    string senderId;
    # Principal that posted it on the sender's behalf, e.g. the workflow's service account
    string actingPrincipal?;
    # Kind
    MessageKind kind;
    # STREAMING or COMPLETE
    MessageStatus status;
    # Content; for a STREAMING message, the text so far
    json content;
    # Message this one answers
    string replyTo?;
    # RFC 3339 creation time
    string createdAt;
    # RFC 3339 time streaming completed
    string completedAt?;
    # RFC 3339 time a FORM was answered
    string answeredAt?;
|};

# A slice of a conversation's history, oldest first.
public type MessagePage record {|
    # Messages, by ascending `seq`
    Message[] items;
    # Whether more messages lie beyond this slice in the direction read
    boolean hasMore;
|};

# Which slice of history to read. Without `afterSeq`, the latest messages are returned.
public type HistoryOptions record {|
    # Messages after this `seq`, oldest first
    int? afterSeq = ();
    # Messages before this `seq` (with no `afterSeq`)
    int? beforeSeq = ();
    # Most messages returned
    int? 'limit = ();
|};

# Text appended to a STREAMING message.
public type Chunk record {|
    # The text
    string text;
    # Agent participant posting it
    string senderId?;
|};

# Completes a STREAMING message.
public type Completion record {|
    # Final content; defaults to the streamed text. Pass it from durable code: streamed text lives in memory
    json content?;
    # Agent participant posting it
    string senderId?;
|};

# Signals that a participant is typing.
public type TypingSignal record {|
    # Agent participant typing
    string senderId?;
|};

# Advances the caller's read position.
public type ReadCursor record {|
    # Last `seq` read
    int seq;
|};

# Closes a conversation.
public type CloseRequest record {|
    # Why it is closed
    string reason?;
    # Agent participant closing it
    string senderId?;
|};

# Single-use ticket that authenticates an SSE stream through its URL.
public type StreamTicket record {|
    # Pass as the `ticket` query parameter of `/stream`
    string ticket;
    # Seconds until the ticket expires
    int expiresIn;
|};

# A webhook to register.
public type NewWebhook webhook:NewSubscription;
# A registered webhook.
public type Webhook webhook:Subscription;
# A newly registered webhook with its secret.
public type CreatedWebhook webhook:CreatedSubscription;
# One webhook delivery.
public type WebhookDelivery webhook:Delivery;

# SSE: a conversation the caller takes part in was created. Webhook: the recipient was added to one.
public const EVENT_CONVERSATION_CREATED = "conversation.created";
# SSE and webhook: a conversation was closed.
public const EVENT_CONVERSATION_CLOSED = "conversation.closed";
# SSE: a participant advanced their read position.
public const EVENT_CONVERSATION_READ = "conversation.read";
# SSE: a message was created (possibly STREAMING). Webhook: a complete message other than a FORM_RESPONSE.
public const EVENT_MESSAGE_CREATED = "message.created";
# SSE: text was appended to a STREAMING message.
public const EVENT_MESSAGE_DELTA = "message.delta";
# SSE: a STREAMING message was completed.
public const EVENT_MESSAGE_COMPLETED = "message.completed";
# SSE: a message changed, e.g. a FORM was answered.
public const EVENT_MESSAGE_UPDATED = "message.updated";
# Webhook: a FORM was answered; the data carries the FORM_RESPONSE.
public const EVENT_FORM_SUBMITTED = "form.submitted";
# SSE: a participant is typing.
public const EVENT_TYPING = "typing";

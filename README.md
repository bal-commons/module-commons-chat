# commons/chat

One-on-one conversations between users and AI agents. It supports forms, replies streamed token by token, read
positions, and webhooks registered per participant.

| Module | Contents |
|---|---|
| `chat` | Types and `Client`. Safe to import anywhere. |
| `chat.server` | The HTTP service. Importing it starts the listener. |

## Run it inside an application

```ballerina
import ballerinax/postgresql.driver as _;
import commons/chat.server as _;
```

Pin `commons/chat` and `commons/service_commons` with `repository = "local"` in `Ballerina.toml`.

```toml
[commons.chat.server]
port = 9101                 # default
basePath = "/chat/v1"       # default
ns = "tenant-app"

[commons.chat.server.auth]
enableJwtAuth = true
jwksUrl = "https://localhost:8090/oauth2/jwks"
enforceScopes = true

[commons.chat.server.db]
dbType = "POSTGRESQL"
url = "jdbc:postgresql://localhost:5432/tenantapp"

# The agent's webhook, registered at startup (updated in place on restart).
[[commons.chat.server.webhooks]]
participantId = "agent:maintenance-triage"
url = "http://localhost:9090/agent/chat-events"
secret = "change-me"
events = ["message.created", "form.submitted", "conversation.closed"]   # empty = all
```

Other settings (see `modules/server/config.bal`): `tablePrefix` (`chat_`), scope names, `maxParticipants` (2),
`maxContentLength`, `maxPageSize`, `webhookDelivery` (attempts, backoff, timeout), `ticketTtlSeconds`, `corsAllowOrigins`.

## Who may do what

The chat service enforces membership and scopes only. Who may talk to whom is the application's decision, made
when it creates the conversation.

| Action | Allowed for |
|---|---|
| Create a conversation | `chat:conversation:create` |
| Read, send, stream, mark read, close | Participants (`chat:use`) |
| Post, stream, type or close **as an agent participant** (`senderId`) | `chat:post-as-agent`; the caller is recorded as `actingPrincipal` |
| Read any conversation that has an agent | `chat:post-as-agent` |
| Read any conversation; list by correlation | `chat:admin` (or `chat:post-as-agent`) |
| Close without being a participant | `chat:conversation:close` |
| Manage webhooks | `chat:webhook:manage` |

Privileged scopes (admin, agent, close, webhook) must be held explicitly, even when `enforceScopes` is off.
Anyone else asking for a conversation gets `404`, so conversation IDs don't leak. Users send `TEXT`, `FORM_RESPONSE`
and `ATTACHMENT_REF` messages. Agents can send any kind.

An agent has no identity of its own yet. It is a participant with a stable ID (`agent:<name>`), and the workflow's
service account posts on its behalf.

## API

| Method | Path | |
|---|---|---|
| `POST` | `/conversations` | Create. `201`, or `200` with the existing one when `correlationId` repeats |
| `GET` | `/conversations` | Caller's conversations, most recently active first, with `unread`. `status`, `correlationId`, `cursor`, `limit` |
| `GET` | `/conversations/{id}` | One conversation |
| `GET` | `/admin/conversations` | Any: `participantId`, `correlationId`, `status`, paging |
| `POST` | `/conversations/{id}/messages` | Send. A repeated `id` returns the stored message (`200`) |
| `GET` | `/conversations/{id}/messages` | History, oldest first: `afterSeq`, or latest before `beforeSeq`; `limit` |
| `GET` | `/conversations/{id}/messages/{messageId}` | One message; a STREAMING one shows its text so far |
| `POST` | `/conversations/{id}/messages/{messageId}/chunks` | Append streamed text `{text}` |
| `POST` | `/conversations/{id}/messages/{messageId}/complete` | Finish streaming `{content?}` |
| `POST` | `/conversations/{id}/typing` | Typing indicator |
| `PUT` | `/conversations/{id}/read` | `{seq}`; only moves forward |
| `POST` | `/conversations/{id}/close` | `{reason?}` |
| `POST` / `GET` / `DELETE` | `/webhooks`, `/webhooks/{id}` | Register (returns the secret once), list, remove |
| `GET` | `/webhooks/{id}/deliveries` | Recent deliveries with status, attempts and last error |
| `POST` | `/stream-ticket` | `{ticket, expiresIn}` for a browser `EventSource` |
| `GET` | `/stream` | SSE for all the caller's conversations |

### Message kinds

| Kind | `content` |
|---|---|
| `TEXT`, `SYSTEM` | string |
| `FORM` | `{schema: <JSON Schema>, ...}`; answered once, by someone other than its sender |
| `FORM_RESPONSE` | object of answers, with `replyTo` = the form's ID |
| `ATTACHMENT_REF` | `{name, ...}`, e.g. an attachment case and file |
| `EVENT` | `{type, ...}` |

## Events

| Event | SSE (all participants) | Webhook (participants other than the actor) |
|---|---|---|
| `conversation.created` | ✓ | ✓ `{conversation}` |
| `message.created` | ✓, including STREAMING starts | ✓ complete messages only, not form answers: `{conversationId, correlationId, message}` |
| `message.delta` | ✓ `{conversationId, messageId, text}` | — |
| `message.completed` | ✓ | as `message.created` |
| `message.updated` | ✓, e.g. a form marked answered | — |
| `form.submitted` | — | ✓ the FORM_RESPONSE |
| `typing`, `conversation.read` | ✓, to the others | — |
| `conversation.closed` | ✓ | ✓ `{conversation}` |

UIs should upsert messages by ID: a retried stream sends `message.created` again for the same message. SSE has no
replay. After a reconnect, refetch the conversation list and read each open conversation's history with `afterSeq`.

## Streaming from a durable agent

The model call runs in an activity, and activities retry. Derive the message ID from the workflow instance and step.
A retry then reopens the same message instead of posting the answer twice:

```ballerina
string messageId = string `${instanceId}.${stepId}`;
_ = check chat->startStreaming(conversationId, messageId, AGENT);
foreach string token in tokens {
    check chat->appendChunk(conversationId, messageId, token, AGENT);
}
_ = check chat->completeMessage(conversationId, messageId, fullText, AGENT);
```

Pass the full text to `completeMessage`. Streamed text is held in memory, so it doesn't survive a restart.

## Receiving webhooks in a workflow

Deliveries are signed (`x-commons-signature: sha256=HMAC(secret, "<timestamp>.<body>")`), retried with backoff and
delivered at least once. Verify each delivery, drop duplicates by `eventId`, and route it by `correlationId`:

```ballerina
import commons/service_commons.webhook;

service /agent on new http:Listener(9090) {
    resource function post chat\-events(http:Request req) returns http:Accepted|http:Unauthorized|error {
        webhook:WebhookEvent|error event = webhook:verify(req, chatWebhookSecret);
        if event is error {
            return http:UNAUTHORIZED;
        }
        // look up the workflow instance by event.correlationId and deliver event.data to it
        return http:ACCEPTED;
    }
}
```

## Storage

Tables `chat_conversation`, `chat_participant`, `chat_message`, plus `chat_webhook_subscription` and
`chat_webhook_outbox`. A webhook event is queued in the same transaction as the change that caused it.
Tested on H2. The SQL is kept portable to MySQL and PostgreSQL, but it hasn't been run against them yet.

Design: `docs/demos/tenant-app/proposal.md` §8.

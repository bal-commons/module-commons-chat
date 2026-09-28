# `<commons-conversation>`

One conversation, live: a header with the title and participants, the messages, a typing indicator and a composer.
Agent replies stream in as they are written. `FORM` messages render as fillable forms built from a flat JSON
Schema, and the answer is shown inside the form. `ATTACHMENT_REF` messages render as an upload card
(`<commons-upload-case>`) when `@bal-commons/attachment-ui` is loaded and `attachments-url` is set. Messages are
marked read as they arrive. Use it as the main pane of a chat screen, next to
[`<commons-conversation-list>`](commons-conversation-list.md), or on its own when your app already knows the
conversation ID.

```html
<script type="module" src="https://cdn.jsdelivr.net/npm/@bal-commons/chat-ui@0.1/dist/chat-ui.bundle.js"></script>

<commons-conversation base-url="/api/chat" conversation-id="01J9..." me="u-123"
    style="height: 600px"></commons-conversation>
```

The element is a flex column that fills its height (`height: 100%`); give it or its container a height.

Authentication, installing and theming are covered in the
[guide](https://github.com/bal-commons/module-commons-service-commons/blob/main/ui/docs/guide.md).

## Attributes and properties

| Property | Attribute | Type | Default | Meaning |
|---|---|---|---|---|
| `baseUrl` | `base-url` | `string` | `""` | Chat service base URL. Required |
| `conversationId` | `conversation-id` | `string` | `""` | The conversation to show. Required; changing it loads the new one |
| `me` | `me` | `string` | unset | The caller's user ID. Their messages are drawn on the right as "You"; their own typing is not shown; read marking happens only when it matches a participant |
| `attachmentsUrl` | `attachments-url` | `string` | unset | Attachment service base URL, passed to `<commons-upload-case>` for `ATTACHMENT_REF` messages |
| `auth` | property only | `AuthAdapter` | the `configureAuth` default | Auth adapter for this element's requests. Also passed to the upload cards |

## Events

| Event | When | `detail` | Bubbles / composed | Cancelable |
|---|---|---|---|---|
| `commons-message-sent` | The caller sent a text message and the service accepted it | `{message: Message}` | yes / yes | no |
| `commons-form-submitted` | The caller submitted a form and the service accepted the answer | `{message: Message}`: the `FORM_RESPONSE` message | yes / yes | no |

Upload cards inside the conversation fire their own events (`commons-file-uploaded`, `commons-case-submitted`,
`commons-file-open`, …); they bubble out of the conversation too. See
[`<commons-upload-case>`](https://github.com/bal-commons/module-commons-attachment/blob/main/ui/docs/commons-upload-case.md).

```ts
interface Message {
  id: string;
  conversationId: string;
  seq: number;
  senderId: string;
  actingPrincipal?: string;
  kind: "TEXT" | "SYSTEM" | "FORM" | "FORM_RESPONSE" | "ATTACHMENT_REF" | "EVENT";
  status: "STREAMING" | "COMPLETE";
  content: unknown;          // string for TEXT/SYSTEM, an object of answers for FORM_RESPONSE, FormContent for FORM
  replyTo?: string;          // FORM_RESPONSE: the form's message ID
  createdAt: string;
  completedAt?: string;
  answeredAt?: string;       // FORM: set once answered
}
```

```js
chat.addEventListener("commons-form-submitted", (e) => {
  const answers = e.detail.message.content;      // e.g. {amount: 120, approved: true}
  analytics.track("form_answered", {formId: e.detail.message.replyTo});
});
```

## Methods

| Method | Returns | What it does |
|---|---|---|
| `reload()` | `Promise<void>` | Refetches the conversation and its latest 100 messages, then marks them read |

## CSS parts

| Part | Element |
|---|---|
| `header` | Title and "with …" line (shown once the conversation has loaded) |
| `messages` | The scrolling message list |
| `message` | One message bubble (also system lines) |
| `composer` | The input and Send button (only while the conversation is `OPEN`) |

## Slots

None.

## Behavior

### What is shown

| Kind | Rendering |
|---|---|
| `TEXT` | A bubble with the text (`white-space: pre-wrap`). While `status` is `STREAMING`, a blinking cursor follows the text |
| `SYSTEM` | A centred muted line |
| `FORM` | A form (see below) |
| `FORM_RESPONSE` | Hidden when its form is in the loaded messages (the answer is shown in the form); otherwise a bubble with `key: value · key: value` |
| `ATTACHMENT_REF` | A full (not `compact`) `<commons-upload-case>` for `content.caseId` when the message has a `caseId`, `attachments-url` is set and that element is registered; otherwise a card with `content.name`. The card gets its `base-url` from `attachments-url` |
| `EVENT` | Not shown |

Each bubble shows the sender ("You" for `me`, otherwise the participant's display name or ID) and a relative time.
Messages are ordered by `seq`. The list scrolls to the bottom whenever messages change.

The element loads the latest 100 messages. There is no "load older" control.

### Forms

A `FORM` message's `content` is:

```ts
interface FormContent {
  title?: string;            // default "Form"
  submitLabel?: string;      // default "Submit"
  schema: {
    type?: "object";
    required?: string[];
    properties?: Record<string, {
      type?: "string" | "number" | "integer" | "boolean";
      title?: string;        // the field label; default is the property name
      format?: string;       // "date" gives a date input
      enum?: string[];       // gives a drop-down
      description?: string;  // not rendered
    }>;
  };
}
```

| Schema field | Input |
|---|---|
| `type: "boolean"` | Checkbox; always submitted as `true` or `false` |
| `enum: [...]` | `<select>` with the values; the first is preselected |
| `type: "number"` or `"integer"` | Number input (`step="any"`); submitted as a number |
| `format: "date"` | Date input; submitted as `YYYY-MM-DD` |
| anything else | Text input |

Fields in `required` get the HTML `required` attribute, so the browser blocks an incomplete submit. Empty
non-boolean fields are left out of the answer. The element does not validate beyond that (no `integer` check, no
`minimum`, no nested objects).

A form is read-only when it has been answered (an answer is loaded or `answeredAt` is set), when the caller sent
it (`senderId === me`), or when the conversation is not `OPEN`. An answered form shows the answer's values and
"✓ Answered by you" or "by <name>". The service enforces the same rules: only one answer per form (409 "Form was
already answered"), and not by its sender.

### Live updates

The conversation subscribes to the shared chat feed for its `base-url`.

| Stream event | What the conversation does |
|---|---|
| `message.created`, `message.completed`, `message.updated` | Adds or replaces the message; clears the typing line; marks read if it is from someone else |
| `message.delta` | Appends the chunk to a streaming message that is already loaded |
| `typing` | Shows "<name> is typing…" for 6 seconds (not for `me`) |
| `conversation.created`, `conversation.closed` | Updates the header and hides the composer when closed |
| reconnect | Reloads the conversation and messages (the chat service does not replay events) |

The service publishes these events only to the conversation's participants, so a viewer who is not a participant
(for example an admin reading a conversation) sees a snapshot that does not update.

### Read marking and typing

- After each load and each incoming message from someone else, the element calls `PUT /conversations/{id}/read`
  with the highest loaded `seq`, but only if `me` is one of the participants. Without `me`, nothing is marked read.
- The element shows other participants' typing signals. It does not send typing signals while the caller types;
  use `ChatClient.typing(id)` if you need that.
- Other participants' read positions (`lastReadSeq`) are not displayed.

### What the service decides

- Participants, holders of `chat:admin`, and agent posters (for conversations with an agent) can read a
  conversation; anyone else gets 404, shown as the error.
- Only participants can post and mark read. Users can send `TEXT`, `FORM_RESPONSE` and `ATTACHMENT_REF`;
  `SYSTEM`, `FORM` and `EVENT` are agent-only.
- The composer is shown only while the conversation is `OPEN`; a closed conversation rejects posts.
- With `enforceScopes` on, the token needs `chat:use`.

### States

| State | What shows |
|---|---|
| Loading | An empty message area; the header appears once the conversation has loaded |
| Error (load, send or form submit) | The message in red (`role="alert"`) under the header. It stays until the next successful reload |
| Closed | "Closed · with …" in the header; no composer; forms read-only |

### Accessibility

- The message list is `role="log"` with `aria-live="polite"`, so screen readers announce new messages.
- The composer is a form: Enter sends. The input has `aria-label="Message"`.
- Form fields are native inputs with labels; `required` fields use native validation.

## Recipes

### Plain HTML: open the conversation for an order

```html
<commons-conversation id="chat" base-url="/api/chat" attachments-url="/api/attachments"
    style="height:70vh"></commons-conversation>

<script type="module" src="https://cdn.jsdelivr.net/npm/@bal-commons/attachment-ui@0.1/dist/attachment-ui.bundle.js"></script>
<script type="module">
  import {bearer, ChatClient, configureAuth} from "https://cdn.jsdelivr.net/npm/@bal-commons/chat-ui@0.1/dist/chat-ui.bundle.js";
  configureAuth(bearer(() => sessionStorage.getItem("token")));

  const chat = document.getElementById("chat");
  chat.me = currentUserId();
  const {items} = await new ChatClient("/api/chat").listConversations({correlationId: "order-4711", limit: 1});
  if (items[0]) chat.conversationId = items[0].id;
</script>
```

Loading `attachment-ui` makes upload requests in the conversation render as upload cards.

### React 19

```tsx
import "@bal-commons/chat-ui";
import "@bal-commons/attachment-ui";   // upload cards for ATTACHMENT_REF messages

export function Conversation({id, me}: {id: string; me: string}) {
  return <div style={{height: "70vh"}}>
    <commons-conversation base-url="/api/chat" attachments-url="/api/attachments" conversation-id={id} me={me}
        oncommons-form-submitted={() => toast("Thanks, your answer was sent")}
        oncommons-case-submitted={() => toast("Files submitted")} />
  </div>;
}
```

`commons-case-submitted` comes from the upload card inside the conversation and bubbles out of it.

### List and conversation

See [`<commons-conversation-list>` recipes](commons-conversation-list.md#recipes). For notifications, chats and
files on one page, use
[`<commons-hub>`](https://github.com/bal-commons/commons-hub-ui/blob/main/docs/commons-hub.md).

# `<commons-conversation-list>`

The caller's conversations, most recently active first, kept live. Each row shows the title (or the
`correlationId` when there is no title), "closed" for closed conversations, the caller's unread count, the other
participants and the time of the last activity. Use it as the sidebar of a chat screen and show the chosen
conversation in [`<commons-conversation>`](commons-conversation.md), or, with `correlation-id`, to list the
conversation about one business object.

```html
<script type="module" src="https://cdn.jsdelivr.net/npm/@bal-commons/chat-ui@0.1/dist/chat-ui.bundle.js"></script>

<commons-conversation-list base-url="/api/chat" me="u-123"></commons-conversation-list>
```

Authentication, installing and theming are covered in the
[guide](https://github.com/bal-commons/module-commons-service-commons/blob/main/ui/docs/guide.md).

## Attributes and properties

| Property | Attribute | Type | Default | Meaning |
|---|---|---|---|---|
| `baseUrl` | `base-url` | `string` | `""` | Chat service base URL, e.g. `/api/chat` or `http://localhost:9101/chat/v1`. Required |
| `me` | `me` | `string` | unset | The caller's user ID, as the service sees it. Left out of each row's "with …" line |
| `selected` | `selected` (reflected) | `string` | unset | ID of the highlighted conversation. Set by a click; set it yourself to highlight one |
| `status` | `status` | `"OPEN" \| "CLOSED"` | unset (all) | Lists only open or only closed conversations |
| `correlationId` | `correlation-id` | `string` | unset | Lists only the conversation(s) about this business object |
| `searchable` | `searchable` | `boolean` | `false` | Shows a search box above the list |
| `auth` | property only | `AuthAdapter` | the `configureAuth` default | Auth adapter for this element's requests |

## Events

| Event | When | `detail` | Bubbles / composed | Cancelable |
|---|---|---|---|---|
| `commons-conversation-select` | A row was clicked, or Enter was pressed on a focused row. `selected` is already set | `{conversation: Conversation}` | yes / yes | no |

```ts
interface Conversation {
  id: string;
  correlationId: string;
  status: "OPEN" | "CLOSED";
  title?: string;
  participants: {participantType: "USER" | "AGENT"; participantId: string; displayName?: string; lastReadSeq: number}[];
  lastSeq: number;
  unread?: number;
  createdBy: string;
  createdAt: string;
  updatedAt: string;
  closedAt?: string;
  closeReason?: string;
  metadata?: unknown;
}
```

A typical handler opens the conversation:

```js
list.addEventListener("commons-conversation-select", (e) => {
  chat.conversationId = e.detail.conversation.id;
});
```

## Methods

| Method | Returns | What it does |
|---|---|---|
| `reload()` | `Promise<void>` | Refetches the list |

## CSS parts

| Part | Element |
|---|---|
| `search` | The search box (only with `searchable`) |
| `list` | The `<ul role="listbox">` |
| `item` | One conversation row |
| `empty` | The empty state |

## Slots

| Slot | Replaces |
|---|---|
| `empty` | The "No conversations." text |

## Behavior

### Live updates

The list subscribes to the shared chat feed for its `base-url`. Any message, conversation (created, closed) or
read event refetches the list, debounced by 300 ms, because the order and unread counts depend on every message.
Streamed text chunks and typing signals do not trigger a refetch. A reconnect refetches too.

### What it lists

- The list is one request: `GET /conversations?limit=50` with `status` and `correlationId` when set. There is no
  paging, so it shows at most the 50 most recently active conversations.
- The service lists the conversations the caller is a participant of, ordered by last activity, with the caller's
  unread count (`lastSeq` minus the caller's read position).
- Search filters the loaded rows in the browser. It matches the title, the `correlationId` and the other
  participants' display names or IDs, case-insensitively.
- There is one conversation per `correlationId` (the service returns the existing one when a second is created
  with the same value), so `correlation-id` lists at most one conversation.

### Permissions

With `enforceScopes` on, the token needs `chat:use` (configurable as `scopeUse`). Admin listing
(`/admin/conversations`) is not used by this element.

### States

| State | What shows |
|---|---|
| Loading | "Loading…" (`role="status"`) until the first response arrives |
| Empty, or no search match | The search box (if enabled) and the `empty` slot or "No conversations." |
| Error | Only the error message in red (`role="alert"`); the list and search box are hidden until a reload succeeds |

### Accessibility

- The list is `role="listbox"` with `aria-label="Conversations"`; rows are `role="option"` with `aria-selected`.
- Rows are focusable (`tabindex="0"`); Enter selects. There is no arrow-key navigation; Tab moves between rows.
- The unread count has `aria-label="N unread"`.
- The search box has `aria-label="Search conversations"`.

## Recipes

### Plain HTML: list and conversation side by side

```html
<div style="display:grid; grid-template-columns:300px 1fr; height:600px">
  <commons-conversation-list id="list" base-url="/api/chat" searchable></commons-conversation-list>
  <commons-conversation id="chat" base-url="/api/chat" attachments-url="/api/attachments"></commons-conversation>
</div>

<script type="module">
  import {bearer, configureAuth} from "https://cdn.jsdelivr.net/npm/@bal-commons/chat-ui@0.1/dist/chat-ui.bundle.js";
  configureAuth(bearer(() => sessionStorage.getItem("token")));

  const me = currentUserId();   // the signed-in user's ID
  const list = document.getElementById("list");
  const chat = document.getElementById("chat");
  list.me = me;
  chat.me = me;
  list.addEventListener("commons-conversation-select", (e) => {
    chat.setAttribute("conversation-id", e.detail.conversation.id);
  });
</script>
```

### React 19

```tsx
import "@bal-commons/chat-ui";
import type {Conversation} from "@bal-commons/chat-ui";
import {useState} from "react";

export function ChatScreen({me}: {me: string}) {
  const [selected, setSelected] = useState<string>();
  return <div className="chat-screen">
    <commons-conversation-list base-url="/api/chat" me={me} searchable={true} status="OPEN"
        selected={selected}
        oncommons-conversation-select={(e: CustomEvent<{conversation: Conversation}>) =>
          setSelected(e.detail.conversation.id)} />
    {selected
      ? <commons-conversation base-url="/api/chat" conversation-id={selected} me={me} />
      : <p>Choose a conversation.</p>}
  </div>;
}
```

### The conversation about one object

```html
<commons-conversation-list base-url="/api/chat" correlation-id="order-4711">
  <p slot="empty">No conversation about this order yet.</p>
</commons-conversation-list>
```

# @bal-commons/chat-ui

Web Components for the [commons chat service](../README.md): the caller's conversations, and a live
conversation with replies streamed as they're written, answerable forms, a typing indicator and read marking.
They're built with Lit and work in any framework or in plain HTML.

| Element | What it shows |
|---|---|
| `<commons-conversation-list>` | The caller's conversations, most recently active first, with unread counts |
| `<commons-conversation>` | One conversation: messages, forms (JSON Schema), attachment cards, composer |

Every element on the page shares one live connection per service URL. An `ATTACHMENT_REF` message renders
`<commons-upload-case>` when [`@bal-commons/attachment-ui`](https://github.com/bal-commons/module-commons-attachment/tree/main/ui)
is loaded, and a plain card otherwise.

## Install

```sh
npm install @bal-commons/chat-ui
```

```html
<script type="module" src="https://cdn.jsdelivr.net/npm/@bal-commons/chat-ui@0.1/dist/chat-ui.bundle.js"></script>
```

## Use

```html
<commons-conversation-list id="list" base-url="/api/chat"></commons-conversation-list>
<commons-conversation id="chat" base-url="/api/chat" attachments-url="/api/attachments"></commons-conversation>

<script type="module">
  import {bearer, configureAuth} from "@bal-commons/chat-ui";
  configureAuth(bearer(() => sessionStorage.getItem("token")));

  const me = currentUserId();          // the caller's user ID, as the service sees it
  list.me = me;
  chat.me = me;
  list.addEventListener("commons-conversation-select", (e) =>
    chat.setAttribute("conversation-id", e.detail.conversation.id));
</script>
```

Authentication works as in `@bal-commons/notification-ui` (`bearer`, `devUser` or your own adapter, set with
`configureAuth` or per element with `.auth`).

## Reference

### `<commons-conversation-list>`

| Attribute / property | |
|---|---|
| `base-url` | Chat service base URL (required) |
| `selected` | ID of the highlighted conversation |
| `.me` | The caller's user ID, left out of the "with …" line |

Events: `commons-conversation-select` (`detail.conversation`). Method: `reload()`. CSS parts: `list`, `item`.

### `<commons-conversation>`

| Attribute / property | |
|---|---|
| `base-url` | Chat service base URL (required) |
| `conversation-id` | The conversation to show (required) |
| `attachments-url` | Attachment service base URL, for upload cards |
| `.me` | The caller's user ID: their messages align right, and read marking applies |

Events: `commons-message-sent`, `commons-form-submitted` (`detail.message`). Method: `reload()`.
CSS parts: `header`, `messages`, `message`, `composer`.

Forms: a `FORM` message's `content.schema` is a flat JSON Schema. The supported fields are `string` (with
`format: "date"` or `enum`), `number`/`integer` and `boolean`. A form is answered once; the answer is shown in the
form.

Theme: the `--bc-*` custom properties, as in `@bal-commons/notification-ui`.

## What the service side needs

CORS for cross-origin pages (`corsAllowOrigins`), and a proxy that doesn't buffer `/stream` (SSE):
`proxy_buffering off; proxy_read_timeout 1h; proxy_http_version 1.1; proxy_set_header Connection "";`

## Integration prompt

```text
Add chat to [my app] using the npm package @bal-commons/chat-ui (Lit Web Components; API:
node_modules/@bal-commons/chat-ui/dist/custom-elements.json and its README).

- The chat service is at [base URL, e.g. /api/chat]; the attachment service, if used, at [/api/attachments]
  (then also install @bal-commons/attachment-ui so upload cards render). Proxy both without buffering /stream.
- Authentication: configureAuth(bearer(getToken, onUnauthorized)) once at startup, with [how my app gets the
  access token] and [what it does on a 401].
- Show <commons-conversation-list> in [the sidebar] and <commons-conversation> in [the main pane]. On
  commons-conversation-select, set conversation-id on the conversation element. Set .me on both to [the signed-in
  user's ID].
- Match the design with the --bc-* CSS custom properties on :root; keep dark mode.
- Do not re-implement message fetching, streaming or read tracking; the components do it.
```

## Develop

```sh
npm install && npm run build   # needs @bal-commons/ui-core (npm link ../../service-commons/ui until it is on npm)
```

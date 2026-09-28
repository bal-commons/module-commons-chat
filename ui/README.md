# @bal-commons/chat-ui

Web Components for the [commons chat service](../README.md). They're built with Lit and work in any framework or
in plain HTML.

| Element | What it shows |
|---|---|
| [`<commons-conversation-list>`](docs/commons-conversation-list.md) | The caller's conversations, most recently active first, with unread counts; status and `correlationId` filters, optional search |
| [`<commons-conversation>`](docs/commons-conversation.md) | One conversation: streamed replies, forms (JSON Schema), upload cards, typing indicator, read marking, composer |

Every element on the page shares one live connection per service URL. An `ATTACHMENT_REF` message renders
`<commons-upload-case>` when [`@bal-commons/attachment-ui`](https://github.com/bal-commons/module-commons-attachment/tree/main/ui)
is loaded (set `attachments-url` too), and a plain card otherwise.

Installing, authentication, the live model, proxies, theming, events and framework notes are in the
[guide](https://github.com/bal-commons/module-commons-service-commons/blob/main/ui/docs/guide.md). For
notifications, chats and files on one page, see
[`<commons-hub>`](https://github.com/bal-commons/commons-hub-ui).

## Install

```sh
npm install @bal-commons/chat-ui
```

```html
<script type="module" src="https://cdn.jsdelivr.net/npm/@bal-commons/chat-ui@0.1/dist/chat-ui.bundle.js"></script>
```

> The package is not yet published to npm, so the two lines above don't work yet. Until it is, build it locally:
> `npm install && npm run build` here (after building `@bal-commons/ui-core` in `service-commons/ui` and linking
> it with `npm link ../../service-commons/ui`), then either `npm link` this package into your app or copy
> `dist/chat-ui.bundle.js` into your static files.

## Use

```html
<commons-conversation-list id="list" base-url="/api/chat" searchable></commons-conversation-list>
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
`configureAuth` or per element with `.auth`); see
[authentication](https://github.com/bal-commons/module-commons-service-commons/blob/main/ui/docs/guide.md#authentication).

## Reference

Each element has a full reference page: attributes, events and `detail` shapes, methods, CSS parts, slots, live
behaviour, permissions and recipes.

- [`<commons-conversation-list>`](docs/commons-conversation-list.md): `base-url`, `me`, `selected`, `status`,
  `correlation-id`, `searchable`; event `commons-conversation-select` (`detail.conversation`); method `reload()`;
  parts `search`, `list`, `item`, `empty`; slot `empty`.
- [`<commons-conversation>`](docs/commons-conversation.md): `base-url`, `conversation-id`, `me`, `attachments-url`;
  events `commons-message-sent`, `commons-form-submitted` (`detail.message`); method `reload()`; parts `header`,
  `messages`, `message`, `composer`.

Forms: a `FORM` message's `content.schema` is a flat JSON Schema. The supported fields are `string` (with
`format: "date"` or `enum`), `number`/`integer` and `boolean`. A form is answered once; the answer is shown in the
form.

Theme: the `--bc-*` custom properties; see
[theming](https://github.com/bal-commons/module-commons-service-commons/blob/main/ui/docs/guide.md#theming).

`ChatClient(baseUrl, auth?)` gives typed calls (`listConversations`, `getConversation`, `history`, `sendText`,
`submitForm`, `markRead`, `typing`) and `chatFeed(baseUrl, auth?)` the shared live feed, for custom views.

## What the service side needs

CORS for cross-origin pages (`corsAllowOrigins`), and a proxy that doesn't buffer `/stream` (SSE):
`proxy_buffering off; proxy_read_timeout 1h; proxy_http_version 1.1; proxy_set_header Connection "";`

## Integration prompt

```text
Add chat to [my app] using the npm package @bal-commons/chat-ui (Lit Web Components; API:
node_modules/@bal-commons/chat-ui/dist/custom-elements.json, its README and docs/).

- The chat service is at [base URL, e.g. /api/chat]; the attachment service, if used, at [/api/attachments]
  (then also install @bal-commons/attachment-ui so upload cards render, and set attachments-url on
  <commons-conversation>). Proxy both without buffering /stream.
- Authentication: configureAuth(bearer(getToken, onUnauthorized)) once at startup, with [how my app gets the
  access token] and [what it does on a 401].
- Show <commons-conversation-list searchable> in [the sidebar] and <commons-conversation> in [the main pane],
  giving the conversation element a fixed height. On commons-conversation-select, set conversation-id on the
  conversation element. Set .me on both to [the signed-in user's ID].
- On [detail pages of my business objects], show <commons-conversation-list correlation-id="[the object's ID]">
  for the conversation about that object.
- Match the design with the --bc-* CSS custom properties on :root; keep dark mode.
- Do not re-implement message fetching, streaming or read tracking; the components do it.
```

## Develop

```sh
npm install && npm run build   # needs @bal-commons/ui-core (npm link ../../service-commons/ui until it is on npm)
```

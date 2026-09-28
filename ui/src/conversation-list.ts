import {type AuthAdapter, relativeTime, tokens} from "@bal-commons/ui-core";
import {css, html, LitElement, nothing} from "lit";
import {ChatClient} from "./client.js";
import {feedFor} from "./feed.js";
import type {Conversation} from "./types.js";

/**
 * The caller's conversations, most recently active first, with unread counts, kept live.
 * @fires commons-conversation-select - A conversation was chosen; `detail.conversation`.
 * @csspart list - The conversation list.
 * @csspart item - One conversation.
 */
export class CommonsConversationList extends LitElement {
  static override properties = {
    baseUrl: {type: String, attribute: "base-url"},
    auth: {attribute: false},
    selected: {type: String, reflect: true},
    me: {type: String},
    items: {state: true, attribute: false},
    error: {state: true, attribute: false}
  };

  declare baseUrl: string;
  declare auth?: AuthAdapter;
  /** ID of the highlighted conversation. */
  declare selected?: string;
  /** The caller's user ID, left out of the "with …" line. */
  declare me?: string;
  /** @internal */
  declare items: Conversation[];
  /** @internal */
  declare error?: string;
  private unsubscribe?: () => void;
  private pending?: ReturnType<typeof setTimeout>;

  constructor() {
    super();
    this.baseUrl = "";
    this.items = [];
  }

  static override styles = [tokens, css`
    :host { display: block; }
    ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 4px; }
    li { padding: 8px 10px; border-radius: 6px; border: 1px solid transparent; cursor: pointer; }
    li:hover { background: var(--_surface); }
    li[aria-selected="true"] { border-color: var(--_accent); background: var(--_accent-soft); }
    li:focus-visible { outline: 2px solid var(--_accent); }
    .top { display: flex; gap: 6px; align-items: center; }
    .title { flex: 1; font-weight: 600; font-size: 14px; }
    .unread { background: var(--_accent); color: #fff; border-radius: 10px; padding: 0 7px; font-size: 11px; }
    .closed { font-size: 11px; color: var(--_muted); }
    .meta { font-size: 12px; color: var(--_muted); }
    .empty, .error { padding: 12px; font-size: 13px; color: var(--_muted); }
    .error { color: var(--_error); }
  `];

  override connectedCallback(): void {
    super.connectedCallback();
    if (this.baseUrl) {
      this.start();
    }
  }

  override disconnectedCallback(): void {
    super.disconnectedCallback();
    this.unsubscribe?.();
  }

  override updated(changed: Map<string, unknown>): void {
    if (changed.has("baseUrl") && this.baseUrl && this.isConnected) {
      this.start();
    }
  }

  async reload(): Promise<void> {
    try {
      this.items = (await new ChatClient(this.baseUrl, this.auth).listConversations({limit: 50})).items;
      this.error = undefined;
    } catch (e) {
      this.error = (e as Error).message;
    }
  }

  private start(): void {
    this.unsubscribe?.();
    // Conversation order and unread counts change with every message: refetch, at most once a second.
    this.unsubscribe = feedFor(this.baseUrl, this.auth).subscribe((change) => {
      if (change.type !== "delta" && change.type !== "typing") {
        clearTimeout(this.pending);
        this.pending = setTimeout(() => void this.reload(), 300);
      }
    });
    void this.reload();
  }

  private select(conversation: Conversation): void {
    this.selected = conversation.id;
    this.dispatchEvent(new CustomEvent("commons-conversation-select",
        {detail: {conversation}, bubbles: true, composed: true}));
  }

  override render() {
    if (this.error) {
      return html`<div class="error" role="alert">${this.error}</div>`;
    }
    if (!this.items.length) {
      return html`<div class="empty">No conversations.</div>`;
    }
    return html`<ul part="list" role="listbox" aria-label="Conversations">
      ${this.items.map((c) => {
        const others = c.participants.filter((p) => p.participantId !== this.me)
            .map((p) => p.displayName || p.participantId).join(", ");
        return html`<li part="item" role="option" tabindex="0" aria-selected=${this.selected === c.id}
            @click=${() => this.select(c)} @keydown=${(e: KeyboardEvent) => e.key === "Enter" && this.select(c)}>
          <div class="top">
            <span class="title">${c.title || c.correlationId}</span>
            ${c.status === "CLOSED" ? html`<span class="closed">closed</span>` : nothing}
            ${c.unread ? html`<span class="unread" aria-label="${c.unread} unread">${c.unread}</span>` : nothing}
          </div>
          <div class="meta">with ${others} · <span title=${c.updatedAt}>${relativeTime(c.updatedAt)}</span></div>
        </li>`;
      })}
    </ul>`;
  }
}

if (!customElements.get("commons-conversation-list")) {
  customElements.define("commons-conversation-list", CommonsConversationList);
}

declare global {
  interface HTMLElementTagNameMap {
    "commons-conversation-list": CommonsConversationList;
  }
}

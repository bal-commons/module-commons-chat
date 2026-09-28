import {type AuthAdapter, relativeTime, tokens} from "@bal-commons/ui-core";
import {css, html, LitElement, nothing, type TemplateResult} from "lit";
import {ChatClient} from "./client.js";
import {type ChatChange, feedFor} from "./feed.js";
import type {Conversation, FormContent, Message} from "./types.js";

/**
 * One conversation, live: streamed replies, forms, typing, read marking and a composer.
 * An ATTACHMENT_REF message renders `<commons-upload-case>` when `@bal-commons/attachment-ui` is loaded.
 * @fires commons-message-sent - The caller sent a message; `detail.message`.
 * @fires commons-form-submitted - The caller answered a form; `detail.message` is the answer.
 * @csspart header - Title and participants.
 * @csspart messages - The message list.
 * @csspart message - One message bubble.
 * @csspart composer - The input and send button.
 */
export class CommonsConversation extends LitElement {
  static override properties = {
    baseUrl: {type: String, attribute: "base-url"},
    conversationId: {type: String, attribute: "conversation-id"},
    auth: {attribute: false},
    me: {type: String},
    attachmentsUrl: {type: String, attribute: "attachments-url"},
    conversation: {state: true, attribute: false},
    messages: {state: true, attribute: false},
    typing: {state: true, attribute: false},
    error: {state: true, attribute: false}
  };

  declare baseUrl: string;
  declare conversationId: string;
  declare auth?: AuthAdapter;
  /** The caller's user ID: their messages are drawn on the right. */
  declare me?: string;
  /** Attachment service base URL, passed to `<commons-upload-case>` for ATTACHMENT_REF messages. */
  declare attachmentsUrl?: string;
  /** @internal */
  declare conversation?: Conversation;
  /** @internal */
  declare messages: Map<string, Message>;
  /** @internal */
  declare typing?: string;
  /** @internal */
  declare error?: string;
  private unsubscribe?: () => void;
  private typingTimer?: ReturnType<typeof setTimeout>;

  constructor() {
    super();
    this.baseUrl = "";
    this.conversationId = "";
    this.messages = new Map();
  }

  static override styles = [tokens, css`
    :host { display: flex; flex-direction: column; min-height: 0; height: 100%; background: var(--_surface); }
    header { padding: 12px 16px; background: var(--_bg); border-bottom: 1px solid var(--_border); }
    header .title { font-weight: 600; }
    header .meta { font-size: 12px; color: var(--_muted); }
    .messages { flex: 1; min-height: 0; overflow-y: auto; padding: 16px; display: flex; flex-direction: column; gap: 10px; }
    .msg { max-width: 75%; padding: 9px 12px; border-radius: 12px; background: var(--_bg); border: 1px solid var(--_border);
      word-break: break-word; }
    .text { white-space: pre-wrap; }
    .msg.mine { align-self: flex-end; background: var(--_accent-soft); border-color: transparent; }
    .msg.system { align-self: center; background: none; border: none; color: var(--_muted); font-size: 12px; }
    .from { font-size: 11px; color: var(--_muted); margin-bottom: 2px; }
    .streaming .text::after { content: "▍"; animation: blink 1s steps(2) infinite; }
    @keyframes blink { 50% { opacity: 0; } }
    form, .card { display: grid; gap: 8px; margin-top: 6px; padding: 10px 12px; border: 1px solid var(--_border);
      border-radius: 10px; background: var(--_bg); white-space: normal; }
    label { display: grid; gap: 3px; font-size: 13px; }
    label.check { display: flex; gap: 8px; align-items: center; }
    input, textarea, select { font: inherit; padding: 6px 8px; border: 1px solid var(--_border); border-radius: 6px;
      background: var(--_bg); color: var(--_fg); }
    label.check input { width: auto; }
    button { font: inherit; padding: 6px 12px; border-radius: 6px; border: 1px solid var(--_accent);
      background: var(--_accent); color: #fff; cursor: pointer; }
    button:focus-visible, input:focus-visible { outline: 2px solid var(--_accent); outline-offset: 1px; }
    .done { color: var(--_success); font-size: 13px; }
    .typing { padding: 0 16px 6px; font-size: 12px; color: var(--_muted); }
    .composer { display: flex; gap: 8px; padding: 12px 16px; background: var(--_bg); border-top: 1px solid var(--_border); }
    .composer input { flex: 1; }
    .error { padding: 12px 16px; color: var(--_error); font-size: 13px; }
  `];

  override connectedCallback(): void {
    super.connectedCallback();
    this.unsubscribe?.();
    if (this.baseUrl) {
      this.unsubscribe = feedFor(this.baseUrl, this.auth).subscribe((change) => this.apply(change));
    }
  }

  override disconnectedCallback(): void {
    super.disconnectedCallback();
    this.unsubscribe?.();
  }

  override updated(changed: Map<string, unknown>): void {
    if (changed.has("baseUrl") && this.baseUrl && this.isConnected) {
      this.unsubscribe?.();
      this.unsubscribe = feedFor(this.baseUrl, this.auth).subscribe((change) => this.apply(change));
    }
    if ((changed.has("conversationId") || changed.has("baseUrl")) && this.baseUrl && this.conversationId) {
      void this.reload();
    }
    if (changed.has("messages")) {
      const list = this.renderRoot.querySelector(".messages");
      list?.scrollTo({top: list.scrollHeight});
    }
  }

  async reload(): Promise<void> {
    try {
      const client = this.client();
      const [conversation, history] = await Promise.all([client.getConversation(this.conversationId),
        client.history(this.conversationId, {limit: 100})]);
      this.conversation = conversation;
      this.messages = new Map(history.items.map((m) => [m.id, m]));
      this.error = undefined;
      void this.markRead();
    } catch (e) {
      this.error = (e as Error).message;
    }
  }

  private client(): ChatClient {
    return new ChatClient(this.baseUrl, this.auth);
  }

  private apply(change: ChatChange): void {
    switch (change.type) {
      case "message":
        if (change.message.conversationId === this.conversationId) {
          this.messages = new Map(this.messages).set(change.message.id, change.message);
          this.typing = undefined;
          if (change.message.senderId !== this.me) {
            void this.markRead();
          }
        }
        break;
      case "delta": {
        const message = this.messages.get(change.messageId);
        if (change.conversationId === this.conversationId && message) {
          const text = (typeof message.content === "string" ? message.content : "") + change.text;
          this.messages = new Map(this.messages).set(message.id, {...message, content: text});
          this.typing = undefined;
        }
        break;
      }
      case "typing":
        if (change.conversationId === this.conversationId && change.participantId !== this.me) {
          this.typing = this.nameOf(change.participantId);
          clearTimeout(this.typingTimer);
          this.typingTimer = setTimeout(() => { this.typing = undefined; }, 6000);
        }
        break;
      case "conversation":
        if (change.conversation.id === this.conversationId) {
          this.conversation = change.conversation;
        }
        break;
      case "reconnected":
        void this.reload();
        break;
    }
  }

  private async markRead(): Promise<void> {
    const last = Math.max(0, ...[...this.messages.values()].map((m) => m.seq));
    if (last > 0 && this.conversation?.participants.some((p) => p.participantId === this.me)) {
      await this.client().markRead(this.conversationId, last).catch(() => undefined);
    }
  }

  private nameOf(participantId: string): string {
    const p = this.conversation?.participants.find((x) => x.participantId === participantId);
    return p?.displayName || participantId;
  }

  private async send(e: Event): Promise<void> {
    e.preventDefault();
    const input = (e.target as HTMLFormElement).elements.namedItem("text") as HTMLInputElement;
    const text = input.value.trim();
    if (!text) {
      return;
    }
    input.value = "";
    try {
      const message = await this.client().sendText(this.conversationId, text);
      this.dispatchEvent(new CustomEvent("commons-message-sent", {detail: {message}, bubbles: true, composed: true}));
    } catch (err) {
      this.error = (err as Error).message;
    }
  }

  private async submit(e: Event, form: Message, content: FormContent): Promise<void> {
    e.preventDefault();
    const el = e.target as HTMLFormElement;
    const values: Record<string, unknown> = {};
    for (const [name, field] of Object.entries(content.schema.properties ?? {})) {
      const input = el.elements.namedItem(name) as HTMLInputElement;
      if (field.type === "boolean") {
        values[name] = input.checked;
      } else if (input.value !== "") {
        values[name] = field.type === "number" || field.type === "integer" ? Number(input.value) : input.value;
      }
    }
    try {
      const message = await this.client().submitForm(this.conversationId, form.id, values);
      this.dispatchEvent(new CustomEvent("commons-form-submitted", {detail: {message}, bubbles: true, composed: true}));
    } catch (err) {
      this.error = (err as Error).message;
    }
  }

  override render() {
    const c = this.conversation;
    const sorted = [...this.messages.values()].sort((a, b) => a.seq - b.seq);
    const answers = new Map(sorted.filter((m) => m.kind === "FORM_RESPONSE" && m.replyTo).map((m) => [m.replyTo!, m]));
    const others = c?.participants.filter((p) => p.participantId !== this.me).map((p) => p.displayName || p.participantId);
    return html`
      ${c ? html`<header part="header"><div class="title">${c.title || c.correlationId}</div>
        <div class="meta">${c.status === "CLOSED" ? "Closed · " : ""}with ${others?.join(", ")}</div></header>` : nothing}
      ${this.error ? html`<div class="error" role="alert">${this.error}</div>` : nothing}
      <div class="messages" part="messages" role="log" aria-live="polite">
        ${sorted.filter((m) => m.kind !== "EVENT" && !(m.kind === "FORM_RESPONSE" && m.replyTo && this.messages.has(m.replyTo)))
            .map((m) => this.renderMessage(m, answers.get(m.id)))}
      </div>
      ${this.typing ? html`<div class="typing">${this.typing} is typing…</div>` : nothing}
      ${c?.status === "OPEN" ? html`<form class="composer" part="composer" @submit=${this.send}>
        <input name="text" placeholder="Write a message…" autocomplete="off" aria-label="Message">
        <button type="submit">Send</button></form>` : nothing}
    `;
  }

  private renderMessage(m: Message, answer?: Message): TemplateResult {
    if (m.kind === "SYSTEM") {
      return html`<div class="msg system" part="message">${String(m.content)}</div>`;
    }
    const mine = m.senderId === this.me;
    let body: TemplateResult;
    switch (m.kind) {
      case "FORM":
        body = this.renderForm(m, m.content as FormContent, answer);
        break;
      case "ATTACHMENT_REF":
        body = this.renderAttachment(m.content as {name?: string; caseId?: string});
        break;
      case "FORM_RESPONSE":
        body = html`<div class="text">${Object.entries(m.content as object).map(([k, v]) => `${k}: ${v}`).join(" · ")}</div>`;
        break;
      default:
        body = html`<div class="text">${typeof m.content === "string" ? m.content : JSON.stringify(m.content)}</div>`;
    }
    return html`<div class="msg ${mine ? "mine" : ""} ${m.status === "STREAMING" ? "streaming" : ""}" part="message">
      <div class="from">${mine ? "You" : this.nameOf(m.senderId)} · <span title=${m.createdAt}>${relativeTime(m.createdAt)}</span></div>
      ${body}</div>`;
  }

  private renderForm(m: Message, content: FormContent, answer?: Message): TemplateResult {
    const answered = answer?.content as Record<string, unknown> | undefined;
    const locked = !!answer || !!m.answeredAt || m.senderId === this.me || this.conversation?.status !== "OPEN";
    const required = new Set(content.schema.required ?? []);
    return html`<form @submit=${(e: Event) => this.submit(e, m, content)}>
      <strong>${content.title ?? "Form"}</strong>
      ${Object.entries(content.schema.properties ?? {}).map(([name, field]) => field.type === "boolean"
        ? html`<label class="check"><input type="checkbox" name=${name} ?checked=${answered?.[name] === true}
            ?disabled=${locked}>${field.title ?? name}</label>`
        : field.enum
        ? html`<label>${field.title ?? name}<select name=${name} ?required=${required.has(name)} ?disabled=${locked}>
            ${field.enum.map((v) => html`<option ?selected=${answered?.[name] === v}>${v}</option>`)}</select></label>`
        : html`<label>${field.title ?? name}<input name=${name} ?required=${required.has(name)} ?disabled=${locked}
            .value=${answered?.[name] === undefined ? "" : String(answered[name])} step="any"
            type=${field.type === "number" || field.type === "integer" ? "number" : field.format === "date" ? "date" : "text"}>
          </label>`)}
      ${answer ? html`<div class="done">✓ Answered by ${answer.senderId === this.me ? "you" : this.nameOf(answer.senderId)}</div>`
        : locked ? nothing : html`<button type="submit">${content.submitLabel ?? "Submit"}</button>`}
    </form>`;
  }

  private renderAttachment(ref: {name?: string; caseId?: string}): TemplateResult {
    if (ref.caseId && customElements.get("commons-upload-case")) {
      return html`<commons-upload-case class="card" base-url=${this.attachmentsUrl ?? ""} case-id=${ref.caseId}
          .auth=${this.auth}></commons-upload-case>`;
    }
    return html`<div class="card"><strong>${ref.name ?? "Attachment"}</strong></div>`;
  }
}

if (!customElements.get("commons-conversation")) {
  customElements.define("commons-conversation", CommonsConversation);
}

declare global {
  interface HTMLElementTagNameMap {
    "commons-conversation": CommonsConversation;
  }
}

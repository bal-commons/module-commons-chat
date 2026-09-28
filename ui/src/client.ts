import {type AuthAdapter, request} from "@bal-commons/ui-core";
import type {Conversation, Message} from "./types.js";

// Typed calls to the chat service, as the signed-in user.
export class ChatClient {
  constructor(readonly baseUrl: string, private readonly auth?: AuthAdapter) {}

  listConversations(options: {status?: "OPEN" | "CLOSED"; correlationId?: string; cursor?: string; limit?: number} = {}):
      Promise<{items: Conversation[]; nextCursor?: string}> {
    return request(this.baseUrl, "/conversations", {auth: this.auth, query: {...options}});
  }

  getConversation(id: string): Promise<Conversation> {
    return request(this.baseUrl, `/conversations/${encodeURIComponent(id)}`, {auth: this.auth});
  }

  history(id: string, options: {afterSeq?: number; beforeSeq?: number; limit?: number} = {}):
      Promise<{items: Message[]; hasMore: boolean}> {
    return request(this.baseUrl, `/conversations/${encodeURIComponent(id)}/messages`, {auth: this.auth, query: {...options}});
  }

  sendText(id: string, text: string): Promise<Message> {
    return request(this.baseUrl, `/conversations/${encodeURIComponent(id)}/messages`,
        {method: "POST", body: {content: text}, auth: this.auth});
  }

  submitForm(id: string, formId: string, values: Record<string, unknown>): Promise<Message> {
    return request(this.baseUrl, `/conversations/${encodeURIComponent(id)}/messages`,
        {method: "POST", body: {kind: "FORM_RESPONSE", replyTo: formId, content: values}, auth: this.auth});
  }

  markRead(id: string, seq: number): Promise<unknown> {
    return request(this.baseUrl, `/conversations/${encodeURIComponent(id)}/read`,
        {method: "PUT", body: {seq}, auth: this.auth});
  }

  typing(id: string): Promise<unknown> {
    return request(this.baseUrl, `/conversations/${encodeURIComponent(id)}/typing`, {method: "POST", body: {}, auth: this.auth});
  }
}

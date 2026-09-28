import {type AuthAdapter, LiveStream} from "@bal-commons/ui-core";
import type {Conversation, Message} from "./types.js";

export type ChatChange =
  | {type: "message"; message: Message}
  | {type: "delta"; conversationId: string; messageId: string; text: string}
  | {type: "typing"; conversationId: string; participantId: string}
  | {type: "conversation"; conversation: Conversation}
  | {type: "read"; conversationId: string; participantId: string; seq: number}
  | {type: "reconnected"};

// One live stream per chat service URL, shared by every component on the page. The chat service does not replay
// missed events, so components refetch on `reconnected`.
class ChatFeed extends EventTarget {
  private stream?: LiveStream;
  private users = 0;

  constructor(private readonly baseUrl: string, private readonly auth?: AuthAdapter) {
    super();
  }

  subscribe(listener: (change: ChatChange) => void): () => void {
    const handler = (e: Event) => listener((e as CustomEvent<ChatChange>).detail);
    this.addEventListener("change", handler);
    if (this.users++ === 0) {
      const message = (m: Message) => this.emit({type: "message", message: m});
      const conversation = (c: Conversation) => this.emit({type: "conversation", conversation: c});
      this.stream = new LiveStream(this.baseUrl, {
        "message.created": message,
        "message.completed": message,
        "message.updated": message,
        "message.delta": ({conversationId, messageId, text}) => this.emit({type: "delta", conversationId, messageId, text}),
        "typing": ({conversationId, participantId}) => this.emit({type: "typing", conversationId, participantId}),
        "conversation.created": conversation,
        "conversation.closed": conversation,
        "conversation.read": ({conversationId, participantId, seq}) =>
          this.emit({type: "read", conversationId, participantId, seq})
      }, {auth: this.auth, onReconnect: () => this.emit({type: "reconnected"})});
      this.stream.start();
    }
    return () => {
      this.removeEventListener("change", handler);
      if (--this.users === 0) {
        this.stream?.stop();
        this.stream = undefined;
      }
    };
  }

  private emit(change: ChatChange): void {
    this.dispatchEvent(new CustomEvent("change", {detail: change}));
  }
}

const feeds = new Map<string, ChatFeed>();

export function feedFor(baseUrl: string, auth?: AuthAdapter): ChatFeed {
  let feed = feeds.get(baseUrl);
  if (!feed) {
    feed = new ChatFeed(baseUrl, auth);
    feeds.set(baseUrl, feed);
  }
  return feed;
}

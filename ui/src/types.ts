export type ParticipantType = "USER" | "AGENT";
export type MessageKind = "TEXT" | "SYSTEM" | "FORM" | "FORM_RESPONSE" | "ATTACHMENT_REF" | "EVENT";

export interface Participant {
  participantType: ParticipantType;
  participantId: string;
  displayName?: string;
  lastReadSeq: number;
}

export interface Conversation {
  id: string;
  correlationId: string;
  status: "OPEN" | "CLOSED";
  title?: string;
  participants: Participant[];
  lastSeq: number;
  unread?: number;
  createdBy: string;
  createdAt: string;
  updatedAt: string;
  closedAt?: string;
  closeReason?: string;
  metadata?: unknown;
}

export interface Message {
  id: string;
  conversationId: string;
  seq: number;
  senderId: string;
  actingPrincipal?: string;
  kind: MessageKind;
  status: "STREAMING" | "COMPLETE";
  content: unknown;
  replyTo?: string;
  createdAt: string;
  completedAt?: string;
  answeredAt?: string;
}

// The flat JSON Schema subset a FORM message carries.
export interface FormSchema {
  type?: "object";
  required?: string[];
  properties?: Record<string, {type?: "string" | "number" | "integer" | "boolean"; title?: string; format?: string;
    enum?: string[]; description?: string}>;
}

export interface FormContent {
  title?: string;
  submitLabel?: string;
  schema: FormSchema;
}

import ballerina/sql;
import ballerinax/java.jdbc;
import commons/chat;
import commons/service_commons;
import commons/service_commons.db as sdb;
import commons/service_commons.webhook;

type NotFoundError distinct error;

type ConflictError distinct error;

type InvalidError distinct error;

type ConversationRow record {|
    string id;
    string correlation_id;
    string status;
    string? title;
    int last_seq;
    string created_by;
    int created_at;
    int updated_at;
    int? closed_at;
    string? closed_by;
    string? close_reason;
    string? metadata;
    int? my_read_seq = ();
|};

type ParticipantRow record {|
    string conversation_id;
    string participant_id;
    string participant_type;
    string? display_name;
    int last_read_seq;
|};

type MessageRow record {|
    string conversation_id;
    string id;
    int seq;
    string sender_id;
    string? acting_principal;
    string kind;
    string status;
    string content;
    string? reply_to;
    int created_at;
    int? completed_at;
    int? answered_at;
|};

// Outcome of a send: `created` is false when the ID repeated; a repeat may have reopened (`restarted`) or
// finished (`completed`) a STREAMING message.
type Posted record {|
    chat:Message message;
    boolean created;
    boolean restarted = false;
    boolean completed = false;
    chat:Message? answeredForm = ();
|};

isolated class Store {
    private final jdbc:Client db;
    private final string ns;
    private final string conversationTable;
    private final string participantTable;
    private final string messageTable;
    private final webhook:Webhooks webhooks;

    isolated function init(jdbc:Client db, string ns, string prefix, webhook:Webhooks webhooks) {
        self.db = db;
        self.ns = ns;
        self.conversationTable = prefix + "conversation";
        self.participantTable = prefix + "participant";
        self.messageTable = prefix + "message";
        self.webhooks = webhooks;
    }

    // A repeated correlation ID returns the existing conversation with `false`.
    isolated function createConversation(chat:NewConversation input, string createdBy)
            returns [chat:Conversation, boolean]|error {
        string id = service_commons:newId();
        string correlationId = input?.correlationId ?: id;
        chat:Conversation? existing = check self.findByCorrelation(correlationId);
        if existing is chat:Conversation {
            return [existing, false];
        }
        final int now = service_commons:nowMillis();
        json metadata = input?.metadata;
        final string? metadataText = metadata is () ? () : metadata.toJsonString();
        final string? title = input?.title;
        ParticipantRow[] participants = from chat:NewParticipant p in input.participants
            select {
                conversation_id: id,
                participant_id: p.participantId,
                participant_type: p.participantType,
                display_name: p?.displayName,
                last_read_seq: 0
            };
        chat:Conversation conversation = check toConversation({
            id,
            correlation_id: correlationId,
            status: chat:OPEN,
            title: input?.title,
            last_seq: 0,
            created_by: createdBy,
            created_at: now,
            updated_at: now,
            closed_at: (),
            closed_by: (),
            close_reason: (),
            metadata: metadataText
        }, participants, false);
        final ParticipantRow[] & readonly members = participants.cloneReadOnly();
        final chat:Conversation & readonly created = conversation.cloneReadOnly();
        anydata|error stored = sdb:atomic(isolated function () returns anydata|error {
            _ = check self.db->execute(sql:queryConcat(`INSERT INTO `, sdb:ident(self.conversationTable),
                ` (id, ns, correlation_id, status, title, last_seq, created_by, created_at, updated_at, metadata)
                VALUES (${created.id}, ${self.ns}, ${created.correlationId}, ${chat:OPEN}, ${title}, 0, ${createdBy},
                ${now}, ${now}, ${metadataText})`));
            foreach ParticipantRow p in members {
                _ = check self.db->execute(sql:queryConcat(`INSERT INTO `, sdb:ident(self.participantTable),
                    ` (conversation_id, participant_id, participant_type, display_name, last_read_seq)
                    VALUES (${created.id}, ${p.participant_id}, ${p.participant_type}, ${p.display_name}, 0)`));
            }
            _ = check self.webhooks.enqueue(chat:EVENT_CONVERSATION_CREATED, others(created, createdBy),
                {conversation: created.toJson()}, created.correlationId);
            return ();
        });
        if stored is error {
            error e = stored;
            if sdb:isDuplicateKey(e) {
                chat:Conversation? raced = check self.findByCorrelation(correlationId);
                if raced is chat:Conversation {
                    return [raced, false];
                }
            }
            return e;
        }
        return [conversation, true];
    }

    isolated function getConversation(string id) returns chat:Conversation?|error {
        chat:Conversation[] found = check self.conversations(sql:queryConcat(self.selectConversations(()),
            ` AND c.id = ${id}`), false);
        return found.length() == 0 ? () : found[0];
    }

    isolated function findByCorrelation(string correlationId) returns chat:Conversation?|error {
        chat:Conversation[] found = check self.conversations(sql:queryConcat(self.selectConversations(()),
            ` AND c.correlation_id = ${correlationId}`), false);
        return found.length() == 0 ? () : found[0];
    }

    // Conversations, most recently active first; `unread` is set for the participant a caller lists as.
    isolated function listConversations(string? participantId, boolean withUnread, string? status,
            string? correlationId, string? cursor, int 'limit) returns chat:ConversationPage|error {
        sql:ParameterizedQuery query = self.selectConversations(participantId);
        if status is string {
            query = sql:queryConcat(query, ` AND c.status = ${status}`);
        }
        if correlationId is string {
            query = sql:queryConcat(query, ` AND c.correlation_id = ${correlationId}`);
        }
        if cursor is string {
            [int, string] [updatedAt, id] = check decodeCursor(cursor);
            query = sql:queryConcat(query, ` AND (c.updated_at < ${updatedAt} OR (c.updated_at = ${updatedAt}
                AND c.id < ${id}))`);
        }
        chat:Conversation[] found = check self.conversations(sql:queryConcat(query,
            ` ORDER BY c.updated_at DESC, c.id DESC LIMIT ${'limit + 1}`), withUnread);
        chat:ConversationPage page = {items: found.length() > 'limit ? found.slice(0, 'limit) : found};
        if found.length() > 'limit {
            chat:Conversation last = page.items[page.items.length() - 1];
            page.nextCursor = encodeCursor(check service_commons:fromIso(last.updatedAt), last.id);
        }
        return page;
    }

    isolated function postMessage(chat:Conversation conversation, string actor, string? actingPrincipal,
            chat:NewMessage input) returns Posted|error {
        string id = input?.id ?: service_commons:newId();
        chat:Message? existing = check self.getMessage(conversation.id, id);
        if existing is chat:Message {
            return self.repeat(conversation, existing, actor, input);
        }
        final string? replyTo = input?.replyTo;
        if input.kind == chat:FORM_RESPONSE {
            chat:Message? form = replyTo is string ? check self.getMessage(conversation.id, replyTo) : ();
            if form is () || form.kind != chat:FORM {
                return error InvalidError("replyTo must be a FORM message in this conversation");
            }
            if form.senderId == actor {
                return error InvalidError("A form cannot be answered by its sender");
            }
        }
        final int now = service_commons:nowMillis();
        final chat:Conversation & readonly target = conversation.cloneReadOnly();
        final chat:NewMessage & readonly request = input.cloneReadOnly();
        final string messageId = id;
        anydata|error posted = sdb:atomic(isolated function () returns anydata|error {
            sql:ExecutionResult bumped = check self.db->execute(sql:queryConcat(`UPDATE `,
                sdb:ident(self.conversationTable), ` SET last_seq = last_seq + 1, updated_at = ${now}
                WHERE ns = ${self.ns} AND id = ${target.id} AND status = ${chat:OPEN}`));
            if bumped.affectedRowCount != 1 {
                return error ConflictError("Conversation is closed");
            }
            int seq = check self.db->queryRow(sql:queryConcat(`SELECT last_seq FROM `,
                sdb:ident(self.conversationTable), ` WHERE id = ${target.id}`));
            if request.kind == chat:FORM_RESPONSE {
                sql:ExecutionResult claimed = check self.db->execute(sql:queryConcat(`UPDATE `,
                    sdb:ident(self.messageTable), ` SET answered_at = ${now} WHERE conversation_id = ${target.id}
                    AND id = ${replyTo} AND answered_at IS NULL`));
                if claimed.affectedRowCount != 1 {
                    return error ConflictError("Form was already answered");
                }
            }
            MessageRow row = {
                conversation_id: target.id,
                id: messageId,
                seq,
                sender_id: actor,
                acting_principal: actingPrincipal,
                kind: request.kind,
                status: request.status,
                content: request.content.toJsonString(),
                reply_to: replyTo,
                created_at: now,
                completed_at: (),
                answered_at: ()
            };
            // A sender has read everything up to their own message.
            _ = check self.db->execute(sql:queryConcat(`UPDATE `, sdb:ident(self.participantTable),
                ` SET last_read_seq = ${seq} WHERE conversation_id = ${target.id} AND participant_id = ${actor}`));
            _ = check self.db->execute(sql:queryConcat(`INSERT INTO `, sdb:ident(self.messageTable),
                ` (conversation_id, id, seq, sender_id, acting_principal, kind, status, content, reply_to, created_at)
                VALUES (${row.conversation_id}, ${messageId}, ${seq}, ${actor}, ${actingPrincipal}, ${row.kind}, ${row.status},
                ${row.content}, ${replyTo}, ${now})`));
            chat:Message created = check toMessage(row);
            if request.status == chat:COMPLETE {
                string event = request.kind == chat:FORM_RESPONSE ? chat:EVENT_FORM_SUBMITTED : chat:EVENT_MESSAGE_CREATED;
                _ = check self.webhooks.enqueue(event, others(target, actor), messageEvent(target, created),
                    target.correlationId);
            }
            return created;
        });
        if posted is error {
            error e = posted;
            if sdb:isDuplicateKey(e) {
                chat:Message? raced = check self.getMessage(conversation.id, id);
                if raced is chat:Message {
                    return self.repeat(conversation, raced, actor, input);
                }
            }
            return e;
        }
        string? formId = replyTo;
        chat:Message? answeredForm = formId is string && input.kind == chat:FORM_RESPONSE
            ? check self.getMessage(conversation.id, formId) : ();
        return {message: check posted.ensureType(), created: true, answeredForm};
    }

    isolated function completeMessage(chat:Conversation conversation, string id, string actor, json content)
            returns chat:Message|error {
        final int now = service_commons:nowMillis();
        final chat:Conversation & readonly target = conversation.cloneReadOnly();
        final string text = content.toJsonString();
        anydata completed = check sdb:atomic(isolated function () returns anydata|error {
            sql:ExecutionResult result = check self.db->execute(sql:queryConcat(`UPDATE `,
                sdb:ident(self.messageTable), ` SET status = ${chat:COMPLETE}, content = ${text},
                completed_at = ${now} WHERE conversation_id = ${target.id} AND id = ${id}
                AND status = ${chat:STREAMING} AND sender_id = ${actor}`));
            if result.affectedRowCount != 1 {
                return error ConflictError(string `Message ${id} is not streaming`);
            }
            _ = check self.db->execute(sql:queryConcat(`UPDATE `, sdb:ident(self.conversationTable),
                ` SET updated_at = ${now} WHERE id = ${target.id}`));
            chat:Message message = check (check self.getMessage(target.id, id)).ensureType();
            _ = check self.webhooks.enqueue(chat:EVENT_MESSAGE_CREATED, others(target, actor),
                messageEvent(target, message), target.correlationId);
            return message;
        });
        return completed.ensureType();
    }

    isolated function close(chat:Conversation conversation, string actor, string? reason)
            returns chat:Conversation|error {
        final int now = service_commons:nowMillis();
        final chat:Conversation & readonly target = conversation.cloneReadOnly();
        anydata closed = check sdb:atomic(isolated function () returns anydata|error {
            sql:ExecutionResult result = check self.db->execute(sql:queryConcat(`UPDATE `,
                sdb:ident(self.conversationTable), ` SET status = ${chat:CLOSED}, closed_at = ${now},
                closed_by = ${actor}, close_reason = ${reason}, updated_at = ${now}
                WHERE ns = ${self.ns} AND id = ${target.id} AND status = ${chat:OPEN}`));
            if result.affectedRowCount != 1 {
                return error ConflictError("Conversation is already closed");
            }
            chat:Conversation updated = check (check self.getConversation(target.id)).ensureType();
            _ = check self.webhooks.enqueue(chat:EVENT_CONVERSATION_CLOSED, others(target, actor),
                {conversation: updated.toJson()}, target.correlationId);
            return updated;
        });
        return closed.ensureType();
    }

    // Moves the read position forward only; returns the participant.
    isolated function markRead(string conversationId, string participantId, int seq) returns chat:Participant|error {
        _ = check self.db->execute(sql:queryConcat(`UPDATE `, sdb:ident(self.participantTable),
            ` SET last_read_seq = ${seq} WHERE conversation_id = ${conversationId} AND participant_id = ${participantId}
            AND last_read_seq < ${seq}`));
        ParticipantRow row = check self.db->queryRow(sql:queryConcat(`SELECT conversation_id, participant_id,
            participant_type, display_name, last_read_seq FROM `, sdb:ident(self.participantTable),
            ` WHERE conversation_id = ${conversationId} AND participant_id = ${participantId}`));
        return toParticipant(row);
    }

    isolated function getMessage(string conversationId, string id) returns chat:Message?|error {
        MessageRow[] rows = check self.messages(sql:queryConcat(self.selectMessages(conversationId),
            ` AND id = ${id}`));
        return rows.length() == 0 ? () : check toMessage(rows[0]);
    }

    isolated function history(string conversationId, int? afterSeq, int? beforeSeq, int 'limit)
            returns chat:MessagePage|error {
        sql:ParameterizedQuery query = self.selectMessages(conversationId);
        MessageRow[] rows;
        if afterSeq is int {
            rows = check self.messages(sql:queryConcat(query, ` AND seq > ${afterSeq} ORDER BY seq LIMIT ${'limit + 1}`));
        } else {
            if beforeSeq is int {
                query = sql:queryConcat(query, ` AND seq < ${beforeSeq}`);
            }
            rows = (check self.messages(sql:queryConcat(query, ` ORDER BY seq DESC LIMIT ${'limit + 1}`))).reverse();
        }
        boolean hasMore = rows.length() > 'limit;
        if hasMore {
            rows = afterSeq is int ? rows.slice(0, 'limit) : rows.slice(1);
        }
        return {items: from MessageRow row in rows select check toMessage(row), hasMore};
    }

    // A repeated send: COMPLETE returns the stored message, STREAMING reopens or completes it.
    isolated function repeat(chat:Conversation conversation, chat:Message existing, string actor,
            chat:NewMessage input) returns Posted|error {
        if existing.senderId != actor {
            return error ConflictError(string `Message ${existing.id} was sent by another participant`);
        }
        if existing.status == chat:COMPLETE {
            return {message: existing, created: false};
        }
        if input.status == chat:COMPLETE {
            return {message: check self.completeMessage(conversation, existing.id, actor, input.content),
                created: false, completed: true};
        }
        _ = check self.db->execute(sql:queryConcat(`UPDATE `, sdb:ident(self.messageTable),
            ` SET content = ${input.content.toJsonString()} WHERE conversation_id = ${conversation.id}
            AND id = ${existing.id} AND status = ${chat:STREAMING}`));
        return {message: check (check self.getMessage(conversation.id, existing.id)).ensureType(), created: false,
            restarted: true};
    }

    isolated function selectConversations(string? participantId) returns sql:ParameterizedQuery {
        sql:ParameterizedQuery columns = `SELECT c.id, c.correlation_id, c.status, c.title, c.last_seq, c.created_by,
            c.created_at, c.updated_at, c.closed_at, c.closed_by, c.close_reason, c.metadata`;
        if participantId is () {
            return sql:queryConcat(columns, ` FROM `, sdb:ident(self.conversationTable), ` c WHERE c.ns = ${self.ns}`);
        }
        return sql:queryConcat(columns, `, p.last_read_seq AS my_read_seq FROM `, sdb:ident(self.conversationTable),
            ` c JOIN `, sdb:ident(self.participantTable), ` p ON p.conversation_id = c.id
            AND p.participant_id = ${participantId} WHERE c.ns = ${self.ns}`);
    }

    isolated function conversations(sql:ParameterizedQuery query, boolean withUnread)
            returns chat:Conversation[]|error {
        stream<ConversationRow, sql:Error?> result = self.db->query(query);
        ConversationRow[] rows = check from ConversationRow row in result select row;
        if rows.length() == 0 {
            return [];
        }
        stream<ParticipantRow, sql:Error?> members = self.db->query(sql:queryConcat(`SELECT conversation_id,
            participant_id, participant_type, display_name, last_read_seq FROM `, sdb:ident(self.participantTable),
            ` WHERE conversation_id IN (`, sql:arrayFlattenQuery(rows.map(row => row.id)), `)
            ORDER BY conversation_id, participant_id`));
        map<ParticipantRow[]> byConversation = {};
        check from ParticipantRow member in members
            do {
                ParticipantRow[] list = byConversation[member.conversation_id] ?: [];
                list.push(member);
                byConversation[member.conversation_id] = list;
            };
        return from ConversationRow row in rows
            select check toConversation(row, byConversation[row.id] ?: [], withUnread);
    }

    isolated function selectMessages(string conversationId) returns sql:ParameterizedQuery {
        return sql:queryConcat(`SELECT conversation_id, id, seq, sender_id, acting_principal, kind, status, content,
            reply_to, created_at, completed_at, answered_at FROM `, sdb:ident(self.messageTable),
            ` WHERE conversation_id = ${conversationId}`);
    }

    isolated function messages(sql:ParameterizedQuery query) returns MessageRow[]|error {
        stream<MessageRow, sql:Error?> rows = self.db->query(query);
        return from MessageRow row in rows select row;
    }
}

isolated function others(chat:Conversation conversation, string actor) returns string[] =>
    from chat:Participant p in conversation.participants where p.participantId != actor select p.participantId;

isolated function messageEvent(chat:Conversation conversation, chat:Message message) returns json => {
    conversationId: conversation.id,
    correlationId: conversation.correlationId,
    message: message.toJson()
};

isolated function encodeCursor(int updatedAt, string id) returns string => string `${updatedAt}~${id}`;

isolated function decodeCursor(string cursor) returns [int, string]|error {
    string[] parts = re `~`.split(cursor);
    if parts.length() != 2 {
        return error InvalidError("Invalid cursor");
    }
    int|error updatedAt = int:fromString(parts[0]);
    if updatedAt is error {
        return error InvalidError("Invalid cursor");
    }
    return [updatedAt, parts[1]];
}

isolated function toConversation(ConversationRow row, ParticipantRow[] participants, boolean withUnread)
        returns chat:Conversation|error {
    chat:Conversation conversation = {
        id: row.id,
        correlationId: row.correlation_id,
        status: check row.status.ensureType(),
        participants: from ParticipantRow p in participants select check toParticipant(p),
        lastSeq: row.last_seq,
        createdBy: row.created_by,
        createdAt: service_commons:toIso(row.created_at),
        updatedAt: service_commons:toIso(row.updated_at)
    };
    string? title = row.title;
    if title is string {
        conversation.title = title;
    }
    int? readSeq = row.my_read_seq;
    if withUnread && readSeq is int {
        conversation.unread = row.last_seq - readSeq;
    }
    int? closedAt = row.closed_at;
    if closedAt is int {
        conversation.closedAt = service_commons:toIso(closedAt);
    }
    string? closedBy = row.closed_by;
    if closedBy is string {
        conversation.closedBy = closedBy;
    }
    string? reason = row.close_reason;
    if reason is string {
        conversation.closeReason = reason;
    }
    string? metadata = row.metadata;
    if metadata is string {
        conversation.metadata = check metadata.fromJsonString();
    }
    return conversation;
}

isolated function toParticipant(ParticipantRow row) returns chat:Participant|error {
    chat:Participant participant = {
        participantType: check row.participant_type.ensureType(),
        participantId: row.participant_id,
        lastReadSeq: row.last_read_seq
    };
    string? displayName = row.display_name;
    if displayName is string {
        participant.displayName = displayName;
    }
    return participant;
}

isolated function toMessage(MessageRow row) returns chat:Message|error {
    chat:Message message = {
        id: row.id,
        conversationId: row.conversation_id,
        seq: row.seq,
        senderId: row.sender_id,
        kind: check row.kind.ensureType(),
        status: check row.status.ensureType(),
        content: check row.content.fromJsonString(),
        createdAt: service_commons:toIso(row.created_at)
    };
    string? actingPrincipal = row.acting_principal;
    if actingPrincipal is string {
        message.actingPrincipal = actingPrincipal;
    }
    string? replyTo = row.reply_to;
    if replyTo is string {
        message.replyTo = replyTo;
    }
    int? completedAt = row.completed_at;
    if completedAt is int {
        message.completedAt = service_commons:toIso(completedAt);
    }
    int? answeredAt = row.answered_at;
    if answeredAt is int {
        message.answeredAt = service_commons:toIso(answeredAt);
    }
    return message;
}

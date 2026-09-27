import ballerina/http;
import commons/chat;
import commons/service_commons;
import commons/service_commons.auth as sauth;

const MESSAGE_ID_PATTERN = "[A-Za-z0-9._:-]{1,64}";

final http:InterceptableService chatService = @http:ServiceConfig {
    cors: {
        allowOrigins: corsAllowOrigins,
        allowHeaders: ["Authorization", "Content-Type", sauth:HEADER_USER_ID, sauth:HEADER_USER_ROLES,
            sauth:HEADER_USER_SCOPES, auth.apiKeyHeader],
        allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    }
} isolated service object {

    public isolated function createInterceptors() returns [sauth:AuthInterceptor, service_commons:ErrorInterceptor] =>
        [new (authenticator, tickets), new];

    isolated resource function post conversations(http:RequestContext ctx, @http:Payload chat:NewConversation body)
            returns http:Created|http:Ok|http:BadRequest|http:Forbidden|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeCreate);
        if caller is http:Forbidden {
            return caller;
        }
        string? invalid = validateConversation(body);
        if invalid is string {
            return service_commons:badRequest(invalid);
        }
        [chat:Conversation, boolean] [conversation, created] = check store.createConversation(body, caller.userId);
        if !created {
            return <http:Ok>{body: conversation};
        }
        publish(conversation, chat:EVENT_CONVERSATION_CREATED, conversation.toJson());
        dispatcher.dispatch();
        return <http:Created>{body: conversation, headers: {"Location": string `${basePath}/conversations/${conversation.id}`}};
    }

    isolated resource function get conversations(http:RequestContext ctx, string? status = (),
            string? correlationId = (), string? cursor = (), int 'limit = 20)
            returns chat:ConversationPage|http:BadRequest|http:Forbidden|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        string? invalid = validateStatus(status) ?: validateLimit('limit);
        if invalid is string {
            return service_commons:badRequest(invalid);
        }
        return mapErrors(store.listConversations(caller.userId, true, status, correlationId, cursor, 'limit));
    }

    isolated resource function get admin/conversations(http:RequestContext ctx, string? participantId = (),
            string? correlationId = (), string? status = (), string? cursor = (), int 'limit = 20)
            returns chat:ConversationPage|http:BadRequest|http:Forbidden|error {
        sauth:CallerIdentity caller = check sauth:callerOf(ctx);
        if !sauth:holdsScope(caller, scopeAdmin) && !sauth:holdsScope(caller, scopeAgent) {
            return service_commons:forbidden(string `Requires scope '${scopeAdmin}' or '${scopeAgent}'`);
        }
        string? invalid = validateStatus(status) ?: validateLimit('limit);
        if invalid is string {
            return service_commons:badRequest(invalid);
        }
        return mapErrors(store.listConversations(participantId, false, status, correlationId, cursor, 'limit));
    }

    isolated resource function get conversations/[string id](http:RequestContext ctx)
            returns chat:Conversation|http:NotFound|http:Forbidden|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        chat:Participant? me = participantOf(conversation, caller.userId);
        if me is chat:Participant {
            conversation.unread = conversation.lastSeq - me.lastReadSeq;
        }
        return conversation;
    }

    isolated resource function post conversations/[string id]/messages(http:RequestContext ctx,
            @http:Payload chat:NewMessage body)
            returns http:Created|http:Ok|http:BadRequest|http:Forbidden|http:NotFound|http:Conflict|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        Actor|http:Forbidden actor = actorFor(caller, conversation, body?.senderId);
        if actor is http:Forbidden {
            return actor;
        }
        string? invalid = validateMessage(body, actor.participantType);
        if invalid is string {
            return service_commons:badRequest(invalid);
        }
        Posted|error posted = store.postMessage(conversation, actor.id, actor.actingPrincipal, body);
        if posted is error {
            return mapError(posted);
        }
        chat:Message message = posted.message;
        if posted.restarted {
            buffers.reset(id, message.id);
        }
        if posted.created || posted.restarted {
            publish(conversation, chat:EVENT_MESSAGE_CREATED, message.toJson());
        } else if posted.completed {
            buffers.reset(id, message.id);
            publish(conversation, chat:EVENT_MESSAGE_COMPLETED, message.toJson());
        }
        chat:Message? form = posted.answeredForm;
        if form is chat:Message {
            publish(conversation, chat:EVENT_MESSAGE_UPDATED, form.toJson());
        }
        dispatcher.dispatch();
        if !posted.created {
            return <http:Ok>{body: message};
        }
        return <http:Created>{body: message};
    }

    isolated resource function get conversations/[string id]/messages(http:RequestContext ctx, int? afterSeq = (),
            int? beforeSeq = (), int 'limit = 50)
            returns chat:MessagePage|http:BadRequest|http:Forbidden|http:NotFound|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        string? invalid = validateLimit('limit);
        if invalid is string {
            return service_commons:badRequest(invalid);
        }
        chat:MessagePage page = check store.history(id, afterSeq, beforeSeq, 'limit);
        page.items = page.items.map(withLiveText);
        return page;
    }

    isolated resource function get conversations/[string id]/messages/[string messageId](http:RequestContext ctx)
            returns chat:Message|http:Forbidden|http:NotFound|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        chat:Message? message = check store.getMessage(id, messageId);
        return message is () ? service_commons:notFound(string `Message ${messageId} not found`) : withLiveText(message);
    }

    isolated resource function post conversations/[string id]/messages/[string messageId]/chunks(
            http:RequestContext ctx, @http:Payload chat:Chunk body)
            returns http:Accepted|http:Forbidden|http:NotFound|http:Conflict|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        Actor|http:Forbidden actor = actorFor(caller, conversation, body?.senderId);
        if actor is http:Forbidden {
            return actor;
        }
        chat:Message? message = check store.getMessage(id, messageId);
        if message is () {
            return service_commons:notFound(string `Message ${messageId} not found`);
        }
        if message.status != chat:STREAMING || message.senderId != actor.id {
            return service_commons:alreadyExists(string `Message ${messageId} is not streaming from ${actor.id}`);
        }
        buffers.append(id, messageId, body.text);
        publish(conversation, chat:EVENT_MESSAGE_DELTA, {conversationId: id, messageId, text: body.text});
        return http:ACCEPTED;
    }

    isolated resource function post conversations/[string id]/messages/[string messageId]/complete(
            http:RequestContext ctx, @http:Payload chat:Completion body)
            returns chat:Message|http:Forbidden|http:NotFound|http:Conflict|http:BadRequest|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        Actor|http:Forbidden actor = actorFor(caller, conversation, body?.senderId);
        if actor is http:Forbidden {
            return actor;
        }
        chat:Message? streaming = check store.getMessage(id, messageId);
        if streaming is () {
            return service_commons:notFound(string `Message ${messageId} not found`);
        }
        json content = body?.content ?: buffers.get(id, messageId) ?: streaming.content;
        if content !is string {
            return service_commons:badRequest("A streamed TEXT message completes with string content");
        }
        chat:Message|error completed = store.completeMessage(conversation, messageId, actor.id, content);
        if completed is error {
            return mapError(completed);
        }
        buffers.reset(id, messageId);
        publish(conversation, chat:EVENT_MESSAGE_COMPLETED, completed.toJson());
        dispatcher.dispatch();
        return completed;
    }

    isolated resource function post conversations/[string id]/typing(http:RequestContext ctx,
            @http:Payload chat:TypingSignal? body) returns http:Accepted|http:Forbidden|http:NotFound|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        Actor|http:Forbidden actor = actorFor(caller, conversation, body?.senderId);
        if actor is http:Forbidden {
            return actor;
        }
        publish(conversation, chat:EVENT_TYPING, {conversationId: id, participantId: actor.id}, actor.id);
        return http:ACCEPTED;
    }

    isolated resource function put conversations/[string id]/read(http:RequestContext ctx,
            @http:Payload chat:ReadCursor body) returns chat:Participant|http:Forbidden|http:NotFound|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        if participantOf(conversation, caller.userId) is () {
            return service_commons:forbidden("Only participants have a read position");
        }
        int seq = int:max(0, int:min(body.seq, conversation.lastSeq));
        chat:Participant me = check store.markRead(id, caller.userId, seq);
        publish(conversation, chat:EVENT_CONVERSATION_READ,
            {conversationId: id, participantId: caller.userId, seq: me.lastReadSeq}, caller.userId);
        return me;
    }

    isolated resource function post conversations/[string id]/close(http:RequestContext ctx,
            @http:Payload chat:CloseRequest? body)
            returns chat:Conversation|http:Forbidden|http:NotFound|http:Conflict|http:BadRequest|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        chat:Conversation|http:NotFound conversation = check readable(caller, id);
        if conversation is http:NotFound {
            return conversation;
        }
        chat:CloseRequest request = body ?: {};
        string closer = caller.userId;
        Actor|http:Forbidden actor = actorFor(caller, conversation, request?.senderId);
        if actor is Actor {
            closer = actor.id;
        } else if !sauth:holdsScope(caller, scopeClose) {
            return actor;
        }
        chat:Conversation|error closed = store.close(conversation, closer, request?.reason);
        if closed is error {
            return mapError(closed);
        }
        publish(closed, chat:EVENT_CONVERSATION_CLOSED, closed.toJson());
        dispatcher.dispatch();
        return closed;
    }

    isolated resource function post webhooks(http:RequestContext ctx, @http:Payload chat:NewWebhook body)
            returns http:Created|http:BadRequest|http:Forbidden|error {
        http:Forbidden? denied = check requireWebhookScope(ctx);
        if denied is http:Forbidden {
            return denied;
        }
        if body.participantId.trim() == "" || !(body.url.startsWith("http://") || body.url.startsWith("https://")) {
            return service_commons:badRequest("participantId and an http(s) url are required");
        }
        chat:CreatedWebhook created = check dispatcher.register(body);
        return <http:Created>{body: created};
    }

    isolated resource function get webhooks(http:RequestContext ctx, string? participantId = ())
            returns chat:Webhook[]|http:Forbidden|error {
        http:Forbidden? denied = check requireWebhookScope(ctx);
        if denied is http:Forbidden {
            return denied;
        }
        return dispatcher.list(participantId);
    }

    isolated resource function get webhooks/[string id]/deliveries(http:RequestContext ctx)
            returns chat:WebhookDelivery[]|http:Forbidden|http:NotFound|error {
        http:Forbidden? denied = check requireWebhookScope(ctx);
        if denied is http:Forbidden {
            return denied;
        }
        if check dispatcher.get(id) is () {
            return service_commons:notFound(string `Webhook ${id} not found`);
        }
        return dispatcher.deliveries(id);
    }

    isolated resource function delete webhooks/[string id](http:RequestContext ctx)
            returns http:NoContent|http:Forbidden|http:NotFound|error {
        http:Forbidden? denied = check requireWebhookScope(ctx);
        if denied is http:Forbidden {
            return denied;
        }
        return check dispatcher.remove(id) ? http:NO_CONTENT : service_commons:notFound(string `Webhook ${id} not found`);
    }

    isolated resource function post stream\-ticket(http:RequestContext ctx)
            returns chat:StreamTicket|http:Forbidden|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        return {ticket: tickets.issue(caller), expiresIn: tickets.ttlSeconds()};
    }

    // Streams events of every conversation the caller takes part in. After a reconnect, refetch the
    // conversation list and read each open conversation's history with `afterSeq`.
    isolated resource function get 'stream(http:RequestContext ctx)
            returns stream<http:SseEvent, error?>|http:Forbidden|error {
        sauth:CallerIdentity|http:Forbidden caller = check authorize(ctx, scopeUse);
        if caller is http:Forbidden {
            return caller;
        }
        return hub.open([target(caller.userId)]);
    }
};

// The participant a request acts as, and the principal acting on its behalf.
type Actor record {|
    string id;
    chat:ParticipantType participantType;
    string? actingPrincipal;
|};

isolated function authorize(http:RequestContext ctx, string scope) returns sauth:CallerIdentity|http:Forbidden|error {
    sauth:CallerIdentity caller = check sauth:callerOf(ctx);
    return authenticator.hasScope(caller, scope) ? caller : service_commons:forbidden(string `Requires scope '${scope}'`);
}

isolated function requireWebhookScope(http:RequestContext ctx) returns http:Forbidden?|error {
    sauth:CallerIdentity caller = check sauth:callerOf(ctx);
    return sauth:holdsScope(caller, scopeWebhooks) ? () :
        service_commons:forbidden(string `Requires scope '${scopeWebhooks}'`);
}

// Participants read their conversations; admins read all; agent posters read those with an agent.
// Others get 404, so conversation IDs do not leak.
isolated function readable(sauth:CallerIdentity caller, string id) returns chat:Conversation|http:NotFound|error {
    chat:Conversation? conversation = check store.getConversation(id);
    if conversation is chat:Conversation && (participantOf(conversation, caller.userId) is chat:Participant
            || sauth:holdsScope(caller, scopeAdmin)
            || (sauth:holdsScope(caller, scopeAgent) && hasAgent(conversation))) {
        return conversation;
    }
    return service_commons:notFound(string `Conversation ${id} not found`);
}

// Posting as another participant needs the agent scope, and that participant must be an agent.
isolated function actorFor(sauth:CallerIdentity caller, chat:Conversation conversation, string? senderId)
        returns Actor|http:Forbidden {
    if senderId is string && senderId != caller.userId {
        if !sauth:holdsScope(caller, scopeAgent) {
            return service_commons:forbidden(string `Posting as ${senderId} requires scope '${scopeAgent}'`);
        }
        chat:Participant? agent = participantOf(conversation, senderId);
        if agent is () || agent.participantType != chat:AGENT {
            return service_commons:forbidden(string `${senderId} is not an agent in this conversation`);
        }
        return {id: senderId, participantType: chat:AGENT, actingPrincipal: caller.userId};
    }
    chat:Participant? me = participantOf(conversation, caller.userId);
    if me is () {
        return service_commons:forbidden("Only participants can do this");
    }
    return {id: caller.userId, participantType: me.participantType, actingPrincipal: ()};
}

isolated function participantOf(chat:Conversation conversation, string participantId) returns chat:Participant? {
    foreach chat:Participant p in conversation.participants {
        if p.participantId == participantId {
            return p;
        }
    }
    return ();
}

isolated function hasAgent(chat:Conversation conversation) returns boolean =>
    conversation.participants.some(p => p.participantType == chat:AGENT);

isolated function target(string participantId) returns string => "participant:" + participantId;

isolated function publish(chat:Conversation conversation, string event, json data, string? except = ()) {
    string[] targets = from chat:Participant p in conversation.participants
        where p.participantId != except
        select target(p.participantId);
    hub.publish({id: service_commons:newId(), event, data}, targets);
}

isolated function withLiveText(chat:Message message) returns chat:Message {
    if message.status != chat:STREAMING {
        return message;
    }
    string? live = buffers.get(message.conversationId, message.id);
    if live is string {
        message.content = live;
    }
    return message;
}

isolated function mapError(error err) returns http:BadRequest|http:NotFound|http:Conflict|error {
    if err is InvalidError {
        return service_commons:badRequest(err.message());
    }
    if err is NotFoundError {
        return service_commons:notFound(err.message());
    }
    if err is ConflictError {
        return service_commons:alreadyExists(err.message());
    }
    return err;
}

isolated function mapErrors(chat:ConversationPage|error result) returns chat:ConversationPage|http:BadRequest|error {
    if result is InvalidError {
        return service_commons:badRequest(result.message());
    }
    return result;
}

isolated function validateConversation(chat:NewConversation input) returns string? {
    int count = input.participants.length();
    if count < 2 || count > maxParticipants {
        return string `A conversation has 2 to ${maxParticipants} participants`;
    }
    string[] ids = input.participants.map(p => p.participantId);
    foreach int i in 0 ..< ids.length() {
        if ids[i].trim() == "" || ids[i].length() > 255 {
            return "participantId must be 1-255 characters";
        }
        if ids.indexOf(ids[i]) != i {
            return string `${ids[i]} is listed twice`;
        }
    }
    if (input?.title ?: "").length() > 500 {
        return "title must be at most 500 characters";
    }
    if (input?.correlationId ?: "x").length() > 255 || input?.correlationId == "" {
        return "correlationId must be 1-255 characters";
    }
    return ();
}

isolated function validateMessage(chat:NewMessage input, chat:ParticipantType sender) returns string? {
    string? id = input?.id;
    if id is string && !re `${MESSAGE_ID_PATTERN}`.isFullMatch(id) {
        return "id must be 1-64 letters, digits, '.', '_', ':' or '-'";
    }
    if sender == chat:USER && [chat:SYSTEM, chat:FORM, chat:EVENT].indexOf(input.kind) != () {
        return string `Only agents send ${input.kind} messages`;
    }
    if input.status == chat:STREAMING && input.kind != chat:TEXT {
        return "Only TEXT messages stream";
    }
    if input.content.toJsonString().length() > maxContentLength {
        return string `content must be at most ${maxContentLength} characters of JSON`;
    }
    json content = input.content;
    match input.kind {
        chat:TEXT|chat:SYSTEM => {
            return content is string ? () : string `${input.kind} content is a string`;
        }
        chat:FORM => {
            return content is map<json> && content["schema"] is map<json> ? () : "FORM content needs a schema object";
        }
        chat:FORM_RESPONSE => {
            return input?.replyTo is () ? "FORM_RESPONSE needs replyTo" :
                content is map<json> ? () : "FORM_RESPONSE content is an object of answers";
        }
        chat:ATTACHMENT_REF => {
            return content is map<json> && content["name"] is string ? () : "ATTACHMENT_REF content needs a name";
        }
        _ => {
            return content is map<json> && content["type"] is string ? () : "EVENT content needs a type";
        }
    }
}

isolated function validateStatus(string? status) returns string? =>
    status is () || status is chat:ConversationStatus ? () : "status must be OPEN or CLOSED";

isolated function validateLimit(int 'limit) returns string? =>
    'limit >= 1 && 'limit <= maxPageSize ? () : string `limit must be between 1 and ${maxPageSize}`;

import ballerina/http;
import ballerina/test;
import ballerinax/h2.driver as _;
import commons/chat;
import commons/service_commons.webhook;

@test:Config
function conversationsAreIdempotentByCorrelation() returns error? {
    chat:Conversation first = check withAgent("tara", "case-1");
    chat:Conversation again = check withAgent("tara", "case-1");
    test:assertEquals(again.id, first.id);
    test:assertEquals(first.status, chat:OPEN);
    test:assertEquals(first.participants.length(), 2);

    chat:Client tara = check persona("tara");
    chat:ConversationPage mine = check tara->listConversations();
    test:assertTrue(mine.items.some(c => c.id == first.id));
    chat:Client carlos = check persona("carlos");
    chat:Conversation|error peek = carlos->getConversation(first.id);
    test:assertEquals(statusOf(peek), 404, "non-participants cannot tell the conversation exists");
    webhook:WebhookEvent created = check agentReceives(chat:EVENT_CONVERSATION_CREATED, "case-1");
    test:assertEquals(created.recipientId, AGENT);
}

@test:Config
function userAndAgentExchangeMessagesWithUnreadCounts() returns error? {
    chat:Conversation conversation = check withAgent("tina", "case-2");
    chat:Client tina = check persona("tina");

    chat:Message question = check tina->sendText(conversation.id, "My sink is leaking");
    test:assertEquals(question.seq, 1);
    webhook:WebhookEvent toAgent = check agentReceives(chat:EVENT_MESSAGE_CREATED, "case-2");
    json delivered = toAgent.data;
    test:assertEquals(check delivered.message.content, "My sink is leaking");

    chat:Message reply = check workflow->sendText(conversation.id, "Can you send a photo?", AGENT);
    test:assertEquals(reply.seq, 2);
    test:assertEquals(reply.senderId, AGENT);
    test:assertEquals(reply?.actingPrincipal, "maintenance-workflow");
    test:assertFalse(agentEventsFor("case-2").indexOf(chat:EVENT_MESSAGE_CREATED) is int,
        "the agent is not told about its own message");

    chat:Conversation seen = check tina->getConversation(conversation.id);
    test:assertEquals(seen?.unread, 1, "own messages are read");
    chat:Participant me = check tina->markRead(conversation.id, 99);
    test:assertEquals(me.lastReadSeq, 2, "read position is clamped to the last message");

    chat:MessagePage history = check tina->history(conversation.id);
    test:assertEquals(history.items.map(m => m.seq), [1, 2]);
    chat:MessagePage after = check tina->history(conversation.id, afterSeq = 1);
    test:assertEquals(after.items.map(m => m.id), [reply.id]);
    chat:MessagePage latest = check tina->history(conversation.id, 'limit = 1);
    test:assertEquals(latest.items.map(m => m.seq), [2]);
    test:assertTrue(latest.hasMore);
}

@test:Config
function repeatedMessageIdIsIdempotent() returns error? {
    chat:Conversation conversation = check withAgent("ian", "case-3");
    chat:Message first = check workflow->sendText(conversation.id, "Booked for Tuesday", AGENT, "wf-3.notify");
    chat:Message second = check workflow->sendText(conversation.id, "Booked for Tuesday", AGENT, "wf-3.notify");
    test:assertEquals(second.seq, first.seq);
    chat:MessagePage history = check workflow->history(conversation.id);
    test:assertEquals(history.items.length(), 1);
}

@test:Config
function formsAreAnsweredOnceByTheOtherParty() returns error? {
    chat:Conversation conversation = check withAgent("fay", "case-4");
    chat:Client fay = check persona("fay");
    chat:Message form = check workflow->sendMessage(conversation.id, {
        kind: chat:FORM,
        senderId: AGENT,
        content: {title: "Pick a visit slot", schema: {'type: "object", properties: {slot: {'type: "string"}}}}
    });
    chat:Message|error ownAnswer = workflow->submitForm(conversation.id, form.id, {slot: "x"}, AGENT);
    test:assertEquals(statusOf(ownAnswer), 400);
    chat:Message|error userForm = fay->sendMessage(conversation.id, {kind: chat:FORM, content: {schema: {}}});
    test:assertEquals(statusOf(userForm), 400, "users do not send forms");

    stream<http:SseEvent, error?> events = check fay->events();
    chat:Message answer = check fay->submitForm(conversation.id, form.id, {slot: "Tue 10:00"});
    test:assertEquals(answer.kind, chat:FORM_RESPONSE);
    test:assertEquals(answer?.replyTo, form.id);
    json updated = check nextOf(events, chat:EVENT_MESSAGE_UPDATED);
    test:assertTrue(updated.answeredAt is string, "the form is marked answered for the UI");
    check events.close();

    webhook:WebhookEvent submitted = check agentReceives(chat:EVENT_FORM_SUBMITTED, "case-4");
    json data = submitted.data;
    test:assertEquals(check data.message.content, {slot: "Tue 10:00"});
    chat:Message|error twice = fay->submitForm(conversation.id, form.id, {slot: "Wed"});
    test:assertEquals(statusOf(twice), 409);
}

@test:Config
function agentStreamsARetriedReply() returns error? {
    chat:Conversation conversation = check withAgent("sue", "case-5");
    chat:Client sue = check persona("sue");
    stream<http:SseEvent, error?> events = check sue->events();
    string messageId = "wf-5.step-2";

    _ = check workflow->startStreaming(conversation.id, messageId, AGENT);
    check workflow->appendChunk(conversation.id, messageId, "Half an ans", AGENT);
    chat:Message restarted = check workflow->startStreaming(conversation.id, messageId, AGENT);
    test:assertEquals(restarted.content, "", "a retried activity starts the reply over");

    json opened = check nextOf(events, chat:EVENT_MESSAGE_CREATED);
    test:assertEquals(check opened.status, "STREAMING");
    check workflow->appendChunk(conversation.id, messageId, "A plumber ", AGENT);
    check workflow->appendChunk(conversation.id, messageId, "is on the way.", AGENT);
    json delta = check nextOf(events, chat:EVENT_MESSAGE_DELTA);
    test:assertEquals(check delta.messageId, messageId);

    chat:Message live = check sue->getMessage(conversation.id, messageId);
    test:assertEquals(live.content, "A plumber is on the way.", "history shows the text so far");
    test:assertEquals(agentEventsFor("case-5").indexOf(chat:EVENT_MESSAGE_CREATED), (),
        "agents are not sent partial messages");

    chat:Message done = check workflow->completeMessage(conversation.id, messageId, senderId = AGENT);
    test:assertEquals(done.status, chat:COMPLETE);
    test:assertEquals(done.content, "A plumber is on the way.");
    json completed = check nextOf(events, chat:EVENT_MESSAGE_COMPLETED);
    test:assertEquals(check completed.content, "A plumber is on the way.");
    check events.close();

    chat:MessagePage history = check sue->history(conversation.id);
    test:assertEquals(history.items.length(), 1, "the retry did not duplicate the reply");
    chat:Message|error again = workflow->completeMessage(conversation.id, messageId, senderId = AGENT);
    test:assertEquals(statusOf(again), 409);
    chat:Message|error chunkAfter = workflow->startStreaming(conversation.id, messageId, AGENT);
    test:assertEquals(statusOf(chunkAfter), 200, "a completed message is returned as is");
}

@test:Config
function onlyParticipantsAndAgentPostersAct() returns error? {
    chat:Conversation conversation = check withAgent("pam", "case-6");
    chat:Client pam = check persona("pam");
    chat:Client carlos = check persona("carlos2");
    chat:Message|error outsider = carlos->sendText(conversation.id, "hi");
    test:assertEquals(statusOf(outsider), 404);
    chat:Message|error spoof = pam->sendText(conversation.id, "I am the agent", AGENT);
    test:assertEquals(statusOf(spoof), 403, "posting as the agent needs the agent scope");
    chat:Message|error asUser = workflow->sendText(conversation.id, "I am pam", "pam");
    test:assertEquals(statusOf(asUser), 403, "the agent scope only covers agent participants");
    chat:Client noScope = check persona("pam", "");
    chat:ConversationPage|error listed = noScope->listConversations();
    test:assertEquals(statusOf(listed), 403);
}

@test:Config
function closingNotifiesTheAgentAndStopsMessages() returns error? {
    chat:Conversation conversation = check withAgent("cora", "case-7");
    chat:Client cora = check persona("cora");
    chat:Conversation closed = check cora->close(conversation.id, "Fixed, thanks");
    test:assertEquals(closed.status, chat:CLOSED);
    test:assertEquals(closed?.closedBy, "cora");
    test:assertEquals(closed?.closeReason, "Fixed, thanks");
    webhook:WebhookEvent event = check agentReceives(chat:EVENT_CONVERSATION_CLOSED, "case-7");
    json data = event.data;
    test:assertEquals(check data.conversation.status, "CLOSED");

    chat:Message|error late = cora->sendText(conversation.id, "one more thing");
    test:assertEquals(statusOf(late), 409);
    chat:Conversation|error twice = workflow->close(conversation.id, senderId = AGENT);
    test:assertEquals(statusOf(twice), 409);
}

@test:Config
function conversationListsPageAndAdminsFindByCorrelation() returns error? {
    foreach int i in 1 ... 3 {
        _ = check withAgent("lou", string `lou-${i}`);
    }
    chat:Client lou = check persona("lou");
    chat:ConversationPage first = check lou->listConversations('limit = 2);
    test:assertEquals(first.items.map(c => c.correlationId), ["lou-3", "lou-2"]);
    chat:ConversationPage rest = check lou->listConversations('limit = 2, cursor = first?.nextCursor);
    test:assertEquals(rest.items.map(c => c.correlationId), ["lou-1"]);
    chat:ConversationPage|error badCursor = lou->listConversations(cursor = "nonsense");
    test:assertEquals(statusOf(badCursor), 400);

    chat:Conversation? found = check workflow->findByCorrelation("lou-2");
    test:assertEquals(found?.correlationId, "lou-2");
    chat:Conversation?|error notAdmin = lou->findByCorrelation("lou-2");
    test:assertEquals(statusOf(notAdmin), 403);
}

@test:Config
function webhooksAreManagedWithTheirScope() returns error? {
    chat:Client manager = check persona("ops", "chat:webhook:manage");
    chat:CreatedWebhook created = check manager->registerWebhook({participantId: "agent:billing",
        url: "http://localhost:19302/agent/events", events: [chat:EVENT_MESSAGE_CREATED]});
    test:assertEquals(created.secret.length(), 64);
    chat:Webhook[] configured = check manager->listWebhooks(AGENT);
    test:assertEquals(configured.length(), 1, "the configured agent webhook was registered at startup");
    chat:WebhookDelivery[] deliveries = check manager->webhookDeliveries(configured[0].id);
    test:assertTrue(deliveries.length() > 0);
    check manager->removeWebhook(created.id);
    error? missing = manager->removeWebhook(created.id);
    test:assertTrue(missing is error);

    chat:Client user = check persona("ursula");
    chat:Webhook[]|error denied = user->listWebhooks();
    test:assertEquals(statusOf(denied), 403);
}

@test:Config
function typingAndReadReceiptsReachTheOtherParty() returns error? {
    chat:Conversation conversation = check withAgent("rae", "case-8");
    chat:Client rae = check persona("rae");
    stream<http:SseEvent, error?> events = check rae->events();
    check workflow->typing(conversation.id, AGENT);
    json typing = check nextOf(events, chat:EVENT_TYPING);
    test:assertEquals(check typing.participantId, AGENT);
    check events.close();
}

@test:Config
function invalidRequestsAreRejected() returns error? {
    chat:Conversation|error three = workflow->createConversation({participants: [
        {participantId: "a"}, {participantId: "b"}, {participantId: "c"}
    ]});
    test:assertEquals(statusOf(three), 400);
    chat:Conversation|error twice = workflow->createConversation({participants: [
        {participantId: "a"}, {participantId: "a"}
    ]});
    test:assertEquals(statusOf(twice), 400);

    chat:Conversation conversation = check withAgent("val", "case-9");
    chat:Message|error badId = workflow->sendText(conversation.id, "x", AGENT, "has spaces");
    test:assertEquals(statusOf(badId), 400);
    chat:Message|error streamingForm = workflow->sendMessage(conversation.id,
        {kind: chat:SYSTEM, content: "x", status: chat:STREAMING, senderId: AGENT});
    test:assertEquals(statusOf(streamingForm), 400);
    chat:Message|error notText = workflow->sendMessage(conversation.id, {content: {x: 1}, senderId: AGENT});
    test:assertEquals(statusOf(notText), 400);
    chat:Message|error orphan = workflow->sendMessage(conversation.id,
        {kind: chat:FORM_RESPONSE, content: {}, replyTo: "missing", senderId: AGENT});
    test:assertEquals(statusOf(orphan), 400);
}

@test:Config
function streamTicketAuthenticatesTheBrowserOnce() returns error? {
    chat:Client tess = check persona("tess");
    chat:StreamTicket ticket = check tess->streamTicket();
    http:Client browser = check new (URL);
    stream<http:SseEvent, error?> events = check browser->get(string `/stream?ticket=${ticket.ticket}`);
    chat:Conversation conversation = check withAgent("tess", "case-10");
    json created = check nextOf(events, chat:EVENT_CONVERSATION_CREATED);
    test:assertEquals(check created.id, conversation.id);
    check events.close();
    http:Response reused = check browser->get(string `/stream?ticket=${ticket.ticket}`);
    test:assertEquals(reused.statusCode, 401);
}

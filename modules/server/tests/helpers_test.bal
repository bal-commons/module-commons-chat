import ballerina/http;
import ballerina/lang.runtime;
import commons/chat;
import commons/service_commons;
import commons/service_commons.webhook;

const URL = "http://localhost:19101/chat/v1";
const AGENT = "agent:triage";
const USE = "chat:use";

isolated webhook:WebhookEvent[] agentInbox = [];

// The agent's webhook endpoint, as a workflow would host it.
service /agent on new http:Listener(19302) {
    resource function post events(http:Request req) returns http:Accepted|http:Unauthorized {
        webhook:WebhookEvent|error event = webhook:verify(req, "s3cret");
        if event is error {
            return http:UNAUTHORIZED;
        }
        lock {
            agentInbox.push(event.clone());
        }
        return http:ACCEPTED;
    }
}

final chat:Client workflow = check new (URL, headers = {
    "x-user-id": "maintenance-workflow",
    "x-user-scopes": "chat:use chat:conversation:create chat:post-as-agent"
});

function persona(string userId, string scopes = USE) returns chat:Client|error =>
    new (URL, headers = {"x-user-id": userId, "x-user-scopes": scopes});

function statusOf(any|error result) returns int {
    if result is http:ApplicationResponseError {
        return result.detail().statusCode;
    }
    return result is error ? -1 : 200;
}

function withAgent(string tenant, string correlationId) returns chat:Conversation|error {
    return workflow->createConversation({
        correlationId,
        title: "Kitchen sink leaking",
        participants: [
            {participantId: tenant, displayName: "Tara"},
            {participantType: chat:AGENT, participantId: AGENT, displayName: "Maintenance assistant"}
        ]
    });
}

// Waits for the agent's webhook to receive an event about a conversation.
function agentReceives(string event, string correlationId, decimal timeout = 5) returns webhook:WebhookEvent|error {
    int deadline = service_commons:nowMillis() + <int>(timeout * 1000);
    while service_commons:nowMillis() < deadline {
        lock {
            foreach int i in 0 ..< agentInbox.length() {
                if agentInbox[i].event == event && agentInbox[i]?.correlationId == correlationId {
                    return agentInbox.remove(i).cloneReadOnly();
                }
            }
        }
        runtime:sleep(0.1);
    }
    return error(string `Agent did not receive ${event} for ${correlationId}`);
}

function agentEventsFor(string correlationId) returns string[] {
    lock {
        return (from webhook:WebhookEvent e in agentInbox where e?.correlationId == correlationId select e.event)
            .cloneReadOnly();
    }
}

// Next SSE event with the given name, skipping comments and other events.
function nextOf(stream<http:SseEvent, error?> events, string name) returns json|error {
    int deadline = service_commons:nowMillis() + 10000;
    while service_commons:nowMillis() < deadline {
        record {|http:SseEvent value;|}? next = check events.next();
        if next is () {
            return error("stream ended");
        }
        if next.value.event == name {
            return (next.value.data ?: "null").fromJsonString();
        }
    }
    return error(string `No ${name} event`);
}

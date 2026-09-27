import commons/service_commons.auth as sauth;
import commons/service_commons.db as sdb;
import commons/service_commons.webhook;

# Port of the service's listener.
configurable int port = 9101;
# Base path the service is attached at.
configurable string basePath = "/chat/v1";
# Namespace of every conversation this instance stores and serves.
configurable string ns = "default";
# Prefix of the service's tables; webhook tables use `<prefix>webhook_`.
configurable string tablePrefix = "chat_";
# Listener auth.
configurable sauth:AuthConfig auth = {};
# Database connection.
configurable sdb:DbConfig db = {};
# Webhooks registered at startup, e.g. an agent's endpoint.
configurable webhook:WebhookConfig[] webhooks = [];
# Webhook delivery tuning.
configurable webhook:DispatcherConfig webhookDelivery = {};
# Scope required to take part in conversations: read, send, stream.
configurable string scopeUse = "chat:use";
# Scope required to create conversations.
configurable string scopeCreate = "chat:conversation:create";
# Scope that lets a non-participant close conversations.
configurable string scopeClose = "chat:conversation:close";
# Scope required to post as an agent participant; also grants reading conversations that have one.
configurable string scopeAgent = "chat:post-as-agent";
# Scope required to manage webhooks.
configurable string scopeWebhooks = "chat:webhook:manage";
# Scope that grants reading every conversation.
configurable string scopeAdmin = "chat:admin";
# Most participants per conversation; 2 keeps conversations one-on-one.
configurable int maxParticipants = 2;
# Largest message content, as JSON text.
configurable int maxContentLength = 65536;
# Largest page a listing returns.
configurable int maxPageSize = 100;
# Lifetime of an SSE stream ticket, in seconds.
configurable int ticketTtlSeconds = 60;
# Origins allowed by CORS.
configurable string[] corsAllowOrigins = ["*"];

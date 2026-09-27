import ballerina/http;
import ballerina/log;
import ballerinax/java.jdbc;
import commons/service_commons.auth as sauth;
import commons/service_commons.db as sdb;
import commons/service_commons.sse;
import commons/service_commons.webhook;

listener http:Listener chatListener = new (port);

final jdbc:Client dbClient = check sdb:connect(db);
final webhook:Webhooks dispatcher = check new (dbClient, db.dbType, ns, tablePrefix + "webhook_", webhookDelivery);
final Store store = new (dbClient, ns, tablePrefix, dispatcher);
final sauth:Authenticator authenticator = check new (auth);
final sauth:TicketStore tickets = new (ticketTtlSeconds);
final sse:Hub hub = new;
final Buffers buffers = new;

function init() returns error? {
    check sdb:validatePrefix(tablePrefix);
    if db.initSchema {
        check sdb:migrate(dbClient, db.dbType, tablePrefix, migrations);
        check dispatcher.migrate();
    }
    foreach webhook:WebhookConfig configured in webhooks {
        _ = check dispatcher.upsert(configured);
    }
    check dispatcher.startRetries();
    check chatListener.attach(chatService, basePath);
    log:printInfo(string `Chat service on port ${port} at ${basePath} (ns ${ns}, ${db.dbType}, `
        + string `${webhooks.length()} configured webhooks)`);
}

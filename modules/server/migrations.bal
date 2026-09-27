import commons/service_commons.db as sdb;

final sdb:Migration[] & readonly migrations = [
    {
        version: 1,
        description: "conversations, participants and messages",
        statements: [
            string `CREATE TABLE {prefix}conversation (
                id VARCHAR(26) NOT NULL PRIMARY KEY,
                ns VARCHAR(64) NOT NULL,
                correlation_id VARCHAR(255) NOT NULL,
                status VARCHAR(8) NOT NULL,
                title VARCHAR(500),
                last_seq BIGINT NOT NULL,
                created_by VARCHAR(255) NOT NULL,
                created_at BIGINT NOT NULL,
                updated_at BIGINT NOT NULL,
                closed_at BIGINT,
                closed_by VARCHAR(255),
                close_reason VARCHAR(1000),
                metadata TEXT)`,
            "CREATE UNIQUE INDEX {prefix}conversation_correlation ON {prefix}conversation (ns, correlation_id)",
            "CREATE INDEX {prefix}conversation_activity ON {prefix}conversation (ns, updated_at, id)",
            string `CREATE TABLE {prefix}participant (
                conversation_id VARCHAR(26) NOT NULL,
                participant_id VARCHAR(255) NOT NULL,
                participant_type VARCHAR(8) NOT NULL,
                display_name VARCHAR(255),
                last_read_seq BIGINT NOT NULL,
                PRIMARY KEY (conversation_id, participant_id))`,
            "CREATE INDEX {prefix}participant_member ON {prefix}participant (participant_id)",
            string `CREATE TABLE {prefix}message (
                conversation_id VARCHAR(26) NOT NULL,
                id VARCHAR(64) NOT NULL,
                seq BIGINT NOT NULL,
                sender_id VARCHAR(255) NOT NULL,
                acting_principal VARCHAR(255),
                kind VARCHAR(16) NOT NULL,
                status VARCHAR(16) NOT NULL,
                content TEXT NOT NULL,
                reply_to VARCHAR(64),
                created_at BIGINT NOT NULL,
                completed_at BIGINT,
                answered_at BIGINT,
                PRIMARY KEY (conversation_id, id))`,
            "CREATE UNIQUE INDEX {prefix}message_seq ON {prefix}message (conversation_id, seq)"
        ]
    }
];

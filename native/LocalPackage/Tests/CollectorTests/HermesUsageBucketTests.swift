import DataSource
import Foundation
import SQLite3
import Testing

@testable import Collector

// Hermes' `session_model_usage` buckets: the ledger that carries the task
// spend the `sessions` rollup row omits, and the `last_seen` anchor that keeps
// a long-running session's activity on the day it was spent.

private func hermesTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "tokcat-hermes-buckets-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(nowMs())-\(UInt32.random(in: 0..<UInt32.max))"
        )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Create a writable SQLite fixture db and hand its path to `body`.
private func withHermesDB(_ name: String, _ sql: String, _ body: (String) -> Void) throws {
    let dir = try hermesTempDir(name)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("state.db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close_v2(db) }
    let rc = sqlite3_exec(db, sql, nil, nil, nil)
    #expect(rc == SQLITE_OK, "fixture SQL failed: \(rc)")
    body(path)
}

/// A `sessions` rollup row plus the per-task buckets Hermes also writes.
private let schemaWithBuckets = """
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        model TEXT,
        started_at REAL,
        ended_at REAL,
        last_activity_at REAL,
        message_count INTEGER,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cache_read_tokens INTEGER,
        cache_write_tokens INTEGER,
        reasoning_tokens INTEGER,
        billing_provider TEXT,
        estimated_cost_usd REAL,
        actual_cost_usd REAL
    );
    CREATE TABLE session_model_usage (
        session_id TEXT NOT NULL,
        model TEXT NOT NULL,
        billing_provider TEXT NOT NULL DEFAULT '',
        billing_base_url TEXT NOT NULL DEFAULT '',
        billing_mode TEXT NOT NULL DEFAULT '',
        task TEXT NOT NULL DEFAULT '',
        api_call_count INTEGER NOT NULL DEFAULT 0,
        input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cache_read_tokens INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        reasoning_tokens INTEGER NOT NULL DEFAULT 0,
        estimated_cost_usd REAL NOT NULL DEFAULT 0,
        actual_cost_usd REAL NOT NULL DEFAULT 0,
        first_seen REAL,
        last_seen REAL,
        PRIMARY KEY (session_id, model, billing_provider, billing_base_url, billing_mode, task)
    );
    """

@Suite struct HermesUsageBucketTests {
    /// The rollup row only covers the main turn loop; title generation and
    /// background review live in their own buckets, and reading the session
    /// row alone silently drops them.
    @Test func countsTaskBucketsTheSessionRowOmits() throws {
        try withHermesDB(
            "buckets",
            schemaWithBuckets + """
                INSERT INTO sessions VALUES
                    ('s1', 'deepseek/deepseek-v4.1-flash', 1700000000.0, 0.0, 1700000600.0, 9,
                     100, 20, 300, 0, 5, 'openrouter', 0.0, 0.0);
                INSERT INTO session_model_usage VALUES
                    ('s1', 'deepseek/deepseek-v4.1-flash', 'openrouter', '', '', 'title_generation',
                     1, 5, 1, 0, 0, 0, 0.0, 0.01, 1700000000.0, 1700000000.0),
                    ('s1', 'deepseek/deepseek-v4.1-flash', 'openrouter', '', '', '',
                     84, 100, 20, 300, 0, 5, 0.0, 1.25, 1700000000.0, 1700000600.0),
                    ('s1', 'deepseek/deepseek-v4.1-flash', 'openrouter', '', '', 'background_review',
                     27, 40, 8, 90, 0, 0, 0.0, 0.50, 1700000100.0, 1700000700.0);
                """
        ) { path in
            let messages = parseHermesDB(path)
            // Three buckets, and the rollup row is NOT also emitted for s1.
            #expect(messages.count == 3)
            // One key per (session, model, task, provider) bucket — pinned as a
            // set so the check cannot depend on row order.
            #expect(
                Set(messages.compactMap(\.dedupKey)) == [
                    "hermes:s1:deepseek/deepseek-v4.1-flash::openrouter",
                    "hermes:s1:deepseek/deepseek-v4.1-flash:background_review:openrouter",
                    "hermes:s1:deepseek/deepseek-v4.1-flash:title_generation:openrouter",
                ])
            #expect(messages.allSatisfy { $0.dedupKey?.hasPrefix("hermes:s1:") == true })
            #expect(messages.reduce(0) { $0 + $1.tokens.input } == 145)
            #expect(messages.reduce(0) { $0 + $1.tokens.cacheRead } == 390)
            #expect(messages.reduce(0) { $0 + $1.cost } == 1.76)

            let background = messages.first {
                ($0.dedupKey ?? "").hasSuffix(":background_review:openrouter")
            }
            #expect(background?.tokens.input == 40)
            #expect(background?.providerId == "openrouter")
            #expect(background?.messages == 27)
            // Per-bucket usage values are cumulative, so the bucket is dated at
            // its own last_seen, not at the session's start.
            #expect(background?.timestampMs == 1_700_000_700_000)
        }
    }

    /// A bucket whose last_seen is unset (or zero) still resolves, falling back
    /// to the session's own timestamps.
    @Test func fallsBackToSessionTimestampsWhenLastSeenIsMissing() throws {
        try withHermesDB(
            "no-last-seen",
            schemaWithBuckets + """
                INSERT INTO sessions VALUES
                    ('s1', 'gpt-5.5', 1700000000.0, 1700000500.0, 0.0, 1,
                     10, 2, 0, 0, 0, 'openai', 0.0, 0.0);
                INSERT INTO session_model_usage VALUES
                    ('s1', 'gpt-5.5', 'openai', '', '', '', 1, 10, 2, 0, 0, 0, 0.0, 0.0, 0.0, 0.0);
                """
        ) { path in
            let messages = parseHermesDB(path)
            #expect(messages.count == 1)
            #expect(messages.first?.timestampMs == 1_700_000_000_000)
        }
    }

    /// Sessions with no bucket row (an old database, or a session that only
    /// ever wrote its rollup) still come from `sessions`.
    @Test func rollupCoversSessionsWithoutBuckets() throws {
        try withHermesDB(
            "partial",
            schemaWithBuckets + """
                INSERT INTO sessions VALUES
                    ('s1', 'gpt-5.5', 1700000000.0, 0.0, 1700000600.0, 4,
                     100, 20, 300, 0, 5, 'openai', 0.0, 1.25),
                    ('s2', 'claude-sonnet-4', 1700259200.0, 0.0, 0.0, 2,
                     10, 3, 7, 1, 2, 'anthropic', 0.75, 0.0);
                INSERT INTO session_model_usage VALUES
                    ('s1', 'gpt-5.5', 'openai', '', '', '', 4, 100, 20, 300, 0, 5, 0.0, 1.25, 0.0, 1700000600.0);
                """
        ) { path in
            let messages = parseHermesDB(path)
            #expect(messages.count == 2)
            // s1 from its bucket, s2 from its rollup — never both for one row.
            #expect(messages.filter { $0.dedupKey == "hermes:s2" }.count == 1)
            #expect(messages.first { $0.dedupKey == "hermes:s2" }?.tokens.input == 10)
            #expect(messages.reduce(0) { $0 + $1.tokens.input } == 110)
        }
    }

    /// A database without the bucket table keeps the previous behaviour, which
    /// is what the existing hermes fixtures (and old profiles) rely on.
    @Test func fallsBackToSessionsWhenBucketTableIsAbsent() throws {
        try withHermesDB(
            "rollup-only",
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL,
                ended_at REAL,
                message_count INTEGER,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER,
                billing_provider TEXT,
                estimated_cost_usd REAL,
                actual_cost_usd REAL
            );
            INSERT INTO sessions VALUES
                ('s1', 'gpt-5.5', 1700000000.125, 0.0, 4, 100, 20, 300, 40, 5,
                 'openai-codex', 0.25, 1.25);
            """
        ) { path in
            let messages = parseHermesDB(path)
            #expect(messages.count == 1)
            #expect(messages.first?.dedupKey == "hermes:s1")
            #expect(messages.first?.timestampMs == 1_700_000_000_125)
            #expect(messages.first?.cost == 1.25)
        }
    }

    /// `last_activity_at` is the rollup's equivalent of a bucket's `last_seen`,
    /// so a session still being written keeps today's tab alive.
    @Test func rollupUsesLastActivityWhenPresent() throws {
        try withHermesDB(
            "last-activity",
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                started_at REAL,
                ended_at REAL,
                last_activity_at REAL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER
            );
            INSERT INTO sessions VALUES ('s1', 'gpt-5.5', 1700000000.0, 0.0, 1700099999.0, 1, 2, 3, 4);
            """
        ) { path in
            let messages = parseHermesDB(path)
            #expect(messages.count == 1)
            #expect(messages.first?.timestampMs == 1_700_099_999_000)
            #expect(messages.first?.tokens.total == 10)
        }
    }
}

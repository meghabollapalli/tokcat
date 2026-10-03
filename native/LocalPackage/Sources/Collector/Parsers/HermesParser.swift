import DataSource
import Foundation

// Port of parse_hermes / hermes_db_path / parse_hermes_db / hermes_provider /
// hermes_timestamp_ms (usage_graph.rs:1584-1589, 2076-2238, 2310-2319).

enum HermesParser: UsageParser {
    static let clientName = "hermes"

    static func parse(_ cache: UsageCache?) -> [UsageMessage] {
        guard let path = hermesDBPath() else { return [] }
        return parseHermesDB(path)
    }
}

/// Port of hermes_db_path (usage_graph.rs:2310-2319).
func hermesDBPath() -> String? {
    if let home = ProcessInfo.processInfo.environment["HERMES_HOME"] {
        let p = joinPath(home, "state.db")
        if isFile(p) { return p }
    }
    guard let home = homeDir() else { return nil }
    let p = joinPath(joinPath(home, ".hermes"), "state.db")
    return isFile(p) ? p : nil
}

/// Port of parse_hermes_db (usage_graph.rs:2076-2189) plus the per-task bucket
/// read (see `hermesModelUsageMessages`).
///
/// Two sources, in order:
///
/// 1. `session_model_usage` — one row per (session, model, task) with its own
///    token columns, `last_seen` and `api_call_count`. This is the complete
///    ledger: a session's rollup row in `sessions` covers only the main turn
///    loop, so title generation, background review and subagent tasks are
///    missing from it entirely (on a real profile, ~9% of input and ~14% of
///    cache-read spend).
/// 2. `sessions` — still the fallback for a database that predates the bucket
///    table, and for any session that never wrote a bucket row.
///
/// A session is read from exactly one source, so nothing is counted twice.
func parseHermesDB(_ path: String) -> [UsageMessage] {
    guard let db = SQLiteDatabase(readOnlyAtPath: path) else { return [] }
    let fallbackTs = fileModifiedTimestampMs(path)
    let buckets = hermesModelUsageMessages(db, fallbackTs: fallbackTs)
    return buckets.messages
        + hermesSessionMessages(db, fallbackTs: fallbackTs, skipping: buckets.sessionIDs)
}

/// `session_model_usage` rows: Hermes' own per-task accounting buckets.
///
/// Each bucket is cumulative, so its tokens are timestamped at `last_seen` —
/// the moment that bucket was last spent. Hermes records no per-day breakdown,
/// so a long-running session's spend lands on its latest active day rather than
/// the day it started, which is what keeps today's tab live while a session is
/// still open. Sessions that fit in one day (the common case) are unaffected.
private func hermesModelUsageMessages(
    _ db: SQLiteDatabase, fallbackTs: Int64
) -> (messages: [UsageMessage], sessionIDs: Set<String>) {
    let columns = sqliteTableColumns(db, table: "session_model_usage")
    guard !columns.isEmpty else { return ([], []) }

    // Every column is qualified: `sessions` carries same-named columns
    // (reasoning_tokens, billing_provider, actual_cost_usd, …), so a bare
    // name across this JOIN is ambiguous and sqlite3_prepare fails — which
    // would silently drop the whole bucket ledger.
    func bucket(_ name: String, _ fallback: String) -> String {
        columns.contains(name) ? "COALESCE(m.\(name), \(fallback))" : fallback
    }
    let sessionColumns = sqliteTableColumns(db, table: "sessions")
    func session(_ name: String, _ fallback: String) -> String {
        sessionColumns.contains(name) ? "COALESCE(s.\(name), \(fallback))" : fallback
    }

    let taskExpr = bucket("task", "''")
    let providerExpr = bucket("billing_provider", "''")
    let reasoningExpr = bucket("reasoning_tokens", "0")
    let lastSeenExpr = bucket("last_seen", "0")
    let actualCostExpr = bucket("actual_cost_usd", "0")
    let estimatedCostExpr = bucket("estimated_cost_usd", "0")
    let apiCallsExpr = bucket("api_call_count", "0")
    let startedExpr = session("started_at", "0")
    let endedExpr = session("ended_at", "0")

    let query = """
        SELECT m.session_id, m.model,
            COALESCE(m.input_tokens, 0),
            COALESCE(m.output_tokens, 0),
            COALESCE(m.cache_read_tokens, 0),
            COALESCE(m.cache_write_tokens, 0),
            \(reasoningExpr),
            \(taskExpr),
            \(providerExpr),
            \(lastSeenExpr),
            \(startedExpr),
            \(endedExpr),
            \(actualCostExpr),
            \(estimatedCostExpr),
            \(apiCallsExpr)
        FROM session_model_usage m
        LEFT JOIN sessions s ON s.id = m.session_id
        WHERE m.model IS NOT NULL AND TRIM(m.model) != ''
        ORDER BY m.session_id, m.model, m.task
        """

    guard let stmt = db.prepare(query) else { return ([], []) }
    var out: [UsageMessage] = []
    var sessionIDs = Set<String>()
    while stmt.step() {
        // Any per-column type mismatch skips the row (rusqlite semantics).
        guard let sessionID = stmt.text(0),
            let model = stmt.text(1),
            let input = stmt.i64(2),
            let output = stmt.i64(3),
            let cacheRead = stmt.i64(4),
            let cacheWrite = stmt.i64(5),
            let reasoning = stmt.i64(6),
            let task = stmt.text(7),
            let billingProvider = stmt.text(8),
            let lastSeen = stmt.f64(9),
            let startedAt = stmt.f64(10),
            let endedAt = stmt.f64(11),
            let actualCost = stmt.f64(12),
            let estimatedCost = stmt.f64(13),
            let apiCalls = stmt.i32(14)
        else { continue }

        let provider = hermesProvider(billingProvider, model: model)
        let ts =
            normalizeEpochMsF64(lastSeen)
            ?? normalizeEpochMsF64(startedAt)
            ?? normalizeEpochMsF64(endedAt)
            ?? fallbackTs
        let cost = actualCost > 0.0 ? actualCost : estimatedCost > 0.0 ? estimatedCost : 0.0
        var msg = UsageMessage(
            client: "hermes", modelId: model, providerId: provider,
            timestampMs: ts,
            tokens: TokenBreakdown(
                input: max(input, 0),
                output: max(output, 0),
                cacheRead: max(cacheRead, 0),
                cacheWrite: max(cacheWrite, 0),
                reasoning: max(reasoning, 0)),
            cost: cost)
        msg.messages = max(apiCalls, 1)
        // One key per bucket: a session can hold several, and `task` is what
        // tells them apart (the table's own primary key is wider still).
        msg.dedupKey = "hermes:\(sessionID):\(model):\(task):\(provider)"
        out.append(msg)
        sessionIDs.insert(sessionID)
    }
    return (out, sessionIDs)
}

/// Port of parse_hermes_db (usage_graph.rs:2076-2189): PRAGMA table_info
/// column tolerance with literal-default substitution for missing columns,
/// ORDER BY started_at,id only when started_at exists. Used for databases
/// without `session_model_usage`, and for sessions that never wrote a bucket.
private func hermesSessionMessages(
    _ db: SQLiteDatabase, fallbackTs: Int64, skipping covered: Set<String>
) -> [UsageMessage] {
    let columns = sqliteTableColumns(db, table: "sessions")
    let reasoningExpr = sqliteColumnOr(columns, "reasoning_tokens", "0")
    let providerExpr = sqliteColumnOr(columns, "billing_provider", "''")
    let startedExpr = sqliteColumnOr(columns, "started_at", "0")
    let endedExpr = sqliteColumnOr(columns, "ended_at", "0")
    let lastActivityExpr = sqliteColumnOr(columns, "last_activity_at", "0")
    let actualCostExpr = sqliteColumnOr(columns, "actual_cost_usd", "0")
    let estimatedCostExpr = sqliteColumnOr(columns, "estimated_cost_usd", "0")
    let messageCountExpr = sqliteColumnOr(columns, "message_count", "1")
    let orderExpr = columns.contains("started_at") ? "started_at, id" : "id"

    let query = """
        SELECT id, model,
            COALESCE(input_tokens, 0),
            COALESCE(output_tokens, 0),
            COALESCE(cache_read_tokens, 0),
            COALESCE(cache_write_tokens, 0),
            \(reasoningExpr),
            \(providerExpr),
            \(lastActivityExpr),
            \(startedExpr),
            \(endedExpr),
            \(actualCostExpr),
            \(estimatedCostExpr),
            \(messageCountExpr)
        FROM sessions
        WHERE model IS NOT NULL AND TRIM(model) != ''
        ORDER BY \(orderExpr)
        """

    guard let stmt = db.prepare(query) else { return [] }
    var out: [UsageMessage] = []
    while stmt.step() {
        // Any per-column type mismatch skips the row (rusqlite semantics).
        guard let id = stmt.text(0),
            let model = stmt.text(1),
            let input = stmt.i64(2),
            let output = stmt.i64(3),
            let cacheRead = stmt.i64(4),
            let cacheWrite = stmt.i64(5),
            let reasoning = stmt.i64(6),
            let billingProvider = stmt.text(7),
            let lastActivity = stmt.f64(8),
            let startedAt = stmt.f64(9),
            let endedAt = stmt.f64(10),
            let actualCost = stmt.f64(11),
            let estimatedCost = stmt.f64(12),
            let messageCount = stmt.i32(13)
        else { continue }
        if covered.contains(id) { continue }

        let provider = hermesProvider(billingProvider, model: model)
        // Same anchor as a bucket row, for the same reason: the newest activity
        // this session has recorded. `last_activity_at` is absent from older
        // databases, where this reduces to the previous started_at behaviour.
        let ts = hermesTimestampMs(
            lastActivity, startedAt, endedAt, fallbackTs: fallbackTs)
        let cost = actualCost > 0.0 ? actualCost : estimatedCost > 0.0 ? estimatedCost : 0.0
        var msg = UsageMessage(
            client: "hermes", modelId: model, providerId: provider,
            timestampMs: ts,
            tokens: TokenBreakdown(
                input: max(input, 0),
                output: max(output, 0),
                cacheRead: max(cacheRead, 0),
                cacheWrite: max(cacheWrite, 0),
                reasoning: max(reasoning, 0)),
            cost: cost)
        msg.messages = max(messageCount, 1)
        msg.dedupKey = "hermes:\(id)"
        out.append(msg)
    }
    return out
}

/// Port of hermes_provider (usage_graph.rs:2213-2232).
func hermesProvider(_ billingProvider: String, model: String) -> String {
    let provider = rustTrim(billingProvider).lowercased()
    if provider.contains("anthropic") {
        return "anthropic"
    } else if provider.contains("openai") {
        return "openai"
    } else if provider.contains("google") || provider.contains("gemini") {
        return "google"
    } else if provider.contains("xai") || provider.contains("grok") {
        return "xai"
    } else if provider.contains("deepseek") {
        return "deepseek"
    } else if provider.contains("meta") || provider.contains("llama") {
        return "meta"
    } else if provider.isEmpty {
        return inferProvider(model)
    }
    return provider
}

/// Port of hermes_timestamp_ms (usage_graph.rs:2234-2238): REAL epoch values
/// through the rounding f64 normalizer, newest activity first, then start
/// before end.
func hermesTimestampMs(
    _ lastActivityAt: Double, _ startedAt: Double, _ endedAt: Double, fallbackTs: Int64
) -> Int64 {
    normalizeEpochMsF64(lastActivityAt) ?? normalizeEpochMsF64(startedAt)
        ?? normalizeEpochMsF64(endedAt) ?? fallbackTs
}

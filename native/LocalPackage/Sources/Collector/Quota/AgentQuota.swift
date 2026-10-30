import DataSource
import Foundation

// Port of agent_usage::run() (:293-312).
//
// Each provider is gated by its own isConfigured check: unconfigured agents
// are omitted from the payload entirely (no tile), while configured-but-
// broken ones surface an error snapshot. Output order is fixed (codex,
// claude, grok, cursor) to match the Rust payload.
//
// The Rust version awaits the four providers sequentially; here they run
// concurrently (per the QuotaStore contract) — the payload is identical
// because each snapshot is independent and the order is reassembled below.
public enum AgentQuota {
    public static func run() async -> AgentUsagePayload {
        let generatedAt = QuotaDates.rfc3339Millis(Date())

        async let codex: AgentUsageSnapshot? = CodexQuotaProvider.isConfigured
            ? CodexQuotaProvider.fetch() : nil
        async let claude: AgentUsageSnapshot? = ClaudeQuotaProvider.isConfigured
            ? ClaudeQuotaProvider.fetch() : nil
        async let grok: AgentUsageSnapshot? = GrokQuotaProvider.isConfigured
            ? GrokQuotaProvider.fetch() : nil
        async let cursor: AgentUsageSnapshot? = CursorQuotaProvider.isConfigured
            ? CursorQuotaProvider.fetch() : nil

        // Other Codex accounts (TOKCAT_CODEX_HOMES, path-separated), each
        // reported as its own "codex" snapshot with source "oauth:<home>".
        var extraCodex: [AgentUsageSnapshot] = []
        let mainHome = codexHome().standardizedFileURL.path
        if let extra = ProcessInfo.processInfo.environment["TOKCAT_CODEX_HOMES"] {
            var seen: Set<String> = [mainHome]
            for path in extra.split(separator: ":").map(String.init) where !path.isEmpty {
                let home = URL(fileURLWithPath: path).standardizedFileURL
                guard seen.insert(home.path).inserted,
                      CodexQuotaProvider.isConfigured(home: home) else { continue }
                extraCodex.append(await CodexQuotaProvider.fetch(home: home))
            }
        }

        let agents = await [codex, claude, grok, cursor].compactMap { $0 } + extraCodex
        return AgentUsagePayload(generatedAt: generatedAt, agents: agents)
    }
}

import DataSource

/// Public pricing entry point for callers outside Collector (Halo's agent
/// cockpit prices a single session from its own transcript). Same bundled
/// price table and cache/tier rules as the usage graph.
public enum UsagePricing {
    public static func cost(model: String, provider: String = "", tokens: TokenBreakdown) -> Double {
        let resolvedProvider = provider.isEmpty ? inferProvider(model) : provider
        return estimateCost(model: model, provider: resolvedProvider, tokens: tokens)
    }
}

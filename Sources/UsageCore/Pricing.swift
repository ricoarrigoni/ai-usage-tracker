import Foundation

/// API list prices, in US dollars per million tokens.
public struct ModelPrice: Equatable, Sendable {
    var input, write5m, write1h, cacheRead, output: Double

    func scaled(by factor: Double) -> ModelPrice {
        ModelPrice(
            input: input * factor, write5m: write5m * factor, write1h: write1h * factor,
            cacheRead: cacheRead * factor, output: output * factor
        )
    }
}

/// Tokens that share one price: the same model, speed and prompt-length tier.
struct PricedTokens {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var write5m: Int64 = 0
    var write1h: Int64 = 0
}

/// What logged tokens would cost at API list prices. This isn't what a subscription plan pays.
/// From https://platform.claude.com/docs/en/about-claude/pricing, checked 2026-11-04.
public enum Pricing {
    private static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", ModelPrice(input: 10, write5m: 12.5, write1h: 20, cacheRead: 0.25, output: 50)),
        ("claude-mythos-5-1", ModelPrice(input: 10, write5m: 12.5, write1h: 20, cacheRead: 0.25, output: 50)),
        ("claude-fable-5", ModelPrice(input: 10, write5m: 12.5, write1h: 20, cacheRead: 1, output: 50)),
        ("claude-opus-5-5", ModelPrice(input: 4, write5m: 5, write1h: 8, cacheRead: 0.2, output: 20)),
        ("claude-opus-5", ModelPrice(input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.5, output: 25)),
        ("claude-opus-4-8", ModelPrice(input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.5, output: 25)),
        ("claude-opus-4-7", ModelPrice(input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.5, output: 25)),
        ("claude-opus-4-6", ModelPrice(input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.5, output: 25)),
        ("claude-opus-4-5", ModelPrice(input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.5, output: 25)),
        ("claude-opus-4", ModelPrice(input: 15, write5m: 18.75, write1h: 30, cacheRead: 1.5, output: 75)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, write5m: 2.5, write1h: 4, cacheRead: 0.1, output: 10)),
        ("claude-sonnet-5", ModelPrice(input: 2, write5m: 2.5, write1h: 4, cacheRead: 0.2, output: 10)),
        ("claude-sonnet-4", ModelPrice(input: 3, write5m: 3.75, write1h: 6, cacheRead: 0.3, output: 15)),
        ("claude-haiku-5-5", ModelPrice(input: 0.1, write5m: 0.125, write1h: 0.2, cacheRead: 0.01, output: 0.5)),
        ("claude-haiku-4-5", ModelPrice(input: 1, write5m: 1.25, write1h: 2, cacheRead: 0.1, output: 5)),
        ("claude-3-5-haiku", ModelPrice(input: 0.8, write5m: 1, write1h: 1.6, cacheRead: 0.08, output: 4)),
    ]

    /// The longest matching name wins, so "claude-opus-5-5" isn't priced as "claude-opus-5".
    static func price(model: String, isFast: Bool, isLongPrompt: Bool) -> ModelPrice? {
        guard let base = table
            .filter({ model == $0.prefix || model.hasPrefix($0.prefix + "-") })
            .max(by: { $0.prefix.count < $1.prefix.count })?.price
        else { return nil }
        var factor = isFast ? 2.0 : 1.0
        // Claude Haiku 5.5 costs five times as much per token when a prompt is over 100,000 tokens.
        if isLongPrompt && model.hasPrefix("claude-haiku-5-5") { factor *= 5 }
        return base.scaled(by: factor)
    }

    static func cost(_ tokens: PricedTokens, at price: ModelPrice) -> Double {
        let dollars = Double(tokens.input) * price.input
            + Double(tokens.output) * price.output
            + Double(tokens.cacheRead) * price.cacheRead
            + Double(tokens.write5m) * price.write5m
            + Double(tokens.write1h) * price.write1h
        return dollars / 1_000_000
    }
}

/// A dollar total, and how many replies couldn't be included because their model has no known price.
public struct CostSummary: Equatable, Sendable {
    public var usd: Double = 0
    public var unpricedReplies: Int64 = 0

    public init(usd: Double = 0, unpricedReplies: Int64 = 0) {
        self.usd = usd
        self.unpricedReplies = unpricedReplies
    }
}

/// One figure in the panel's cost row. A nil cost means there's no such period right now.
public struct CostPeriod: Equatable, Sendable, Identifiable {
    public var title: String
    public var usd: Double?

    public var id: String { title }

    public init(title: String, usd: Double?) {
        self.title = title
        self.usd = usd
    }
}

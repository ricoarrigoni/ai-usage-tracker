import Foundation

/// Shows dollar amounts in the currency of this Mac's region.
public struct MoneyFormat: Equatable, Sendable {
    public var code: String
    /// How much of `code` one US dollar buys.
    public var perUSD: Double
    /// The day of the exchange rate, such as "2026-11-04". Nil when nothing was converted.
    public var rateDate: String?

    public static let usd = MoneyFormat(code: "USD", perUSD: 1, rateDate: nil)

    public init(code: String, perUSD: Double, rateDate: String?) {
        self.code = code
        self.perUSD = perUSD
        self.rateDate = rateDate
    }

    public func plain(_ usd: Double) -> String {
        let value = usd * perUSD
        return value.formatted(.currency(code: code).precision(.fractionLength(value >= 100 ? 0 : 2)))
    }

    /// For places whose title doesn't already say the amount is an estimate.
    public func approximate(_ usd: Double) -> String { "≈" + plain(usd) }

    /// Says where a converted amount came from. Nil when amounts are in dollars.
    public var conversionNote: String? {
        guard let rateDate else { return nil }
        return "API prices are in US dollars, converted at the European Central Bank's \(rateDate) rate."
    }

    /// The format for this Mac's region. Stays in dollars until a rate has been downloaded.
    public static func current(locations: Locations, locale: Locale = .current) -> MoneyFormat {
        let code = locale.currency?.identifier ?? "USD"
        return ExchangeRates.load(from: ExchangeRates.file(in: locations))?.format(for: code) ?? .usd
    }
}

/// The European Central Bank's daily reference rates, saved so they work offline.
public struct ExchangeRates: Codable, Equatable, Sendable {
    public static let source = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    public var date: String
    public var fetchedAt: Int64
    /// How much of each currency one euro buys.
    public var perEUR: [String: Double]

    static func file(in locations: Locations) -> URL {
        locations.dataDirectory.appendingPathComponent("exchange-rates.json")
    }

    static func load(from url: URL) -> ExchangeRates? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ExchangeRates.self, from: $0) }
    }

    /// Nil when the feed has no date or no dollar rate, which every real feed has.
    static func parse(_ data: Data, fetchedAt: Date) -> ExchangeRates? {
        let text = String(decoding: data, as: UTF8.self)
        guard let date = text.firstMatch(of: /time=['"](\d{4}-\d{2}-\d{2})['"]/)?.1 else { return nil }
        var perEUR: [String: Double] = [:]
        for match in text.matches(of: /currency=['"]([A-Z]{3})['"]\s+rate=['"]([0-9.]+)['"]/) {
            if let rate = Double(match.2), rate > 0 { perEUR[String(match.1)] = rate }
        }
        guard perEUR["USD"] != nil else { return nil }
        return ExchangeRates(date: String(date), fetchedAt: Int64(fetchedAt.timeIntervalSince1970), perEUR: perEUR)
    }

    /// Nil when the feed doesn't list this currency, so amounts stay in dollars.
    func format(for code: String) -> MoneyFormat? {
        guard let dollars = perEUR["USD"] else { return nil }
        if code == "USD" { return .usd }
        guard let rate = code == "EUR" ? 1 : perEUR[code] else { return nil }
        return MoneyFormat(code: code, perUSD: rate / dollars, rateDate: date)
    }
}

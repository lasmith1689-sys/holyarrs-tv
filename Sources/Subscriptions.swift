import SwiftUI

// What the setup pays for (IPTV, Newshosting, NZBgeek) and when each runs out, from the PC (GET /subscriptions,
// rtx-upscale-stream src/subscriptions.py). Home warns 14 days ahead; Settings lists all of them.

struct Subscription: Identifiable, Hashable {
    let id: String
    let name: String
    let what: String
    let expires: Date?
    let daysLeft: Int?
    /// "ok", "soon" (within 14 days), "expired", "unknown" (no date yet) or "lifetime".
    let state: String

    init?(_ j: JSON) {
        guard let id = j["id"].string, let name = j["name"].string else { return nil }
        self.id = id
        self.name = name
        what = j["what"].string ?? ""
        expires = j["expires"].string.flatMap(Subscription.parse)
        daysLeft = j["days_left"].int
        state = j["state"].string ?? "unknown"
    }

    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    var warn: Bool { state == "soon" || state == "expired" }

    private var date: String {
        guard let expires else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: expires)
    }

    private var days: String {
        let d = daysLeft ?? 0
        return d == 1 ? "1 day" : "\(d) days"
    }

    /// "Until Dec 22, 2026 · 30 days left", "Runs out in 9 days (Dec 1, 2026)", "Date not set yet".
    var line: String {
        switch state {
        case "lifetime": return "Lifetime plan"
        case "expired": return expires == nil ? "Ran out" : "Ran out on \(date)"
        case "soon": return daysLeft == nil ? "Runs out soon" : daysLeft == 0 ? "Runs out today" : "Runs out in \(days) (\(date))"
        case "ok": return "Until \(date) \u{00B7} \(days) left"
        default: return "Date not set yet"
        }
    }

    var color: Color {
        switch state {
        case "expired": return Color(red: 1, green: 0.42, blue: 0.42)
        case "soon": return Theme.accent
        case "ok", "lifetime": return Color(red: 0.36, green: 0.83, blue: 0.62)
        default: return Theme.dim
        }
    }
}

/// On Home: a card when a subscription runs out within 14 days (or has run out).
struct SubscriptionWarning: View {
    @EnvironmentObject private var rtx: RTXServer

    var body: some View {
        let soon = rtx.subscriptions.filter(\.warn)
        if !soon.isEmpty {
            HStack(alignment: .top, spacing: S(24)) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: F(40))).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: S(8)) {
                    ForEach(soon) { s in
                        Text("\(s.name): \(s.line)").font(.system(size: F(28), weight: .semibold))
                    }
                    Text("Renew to keep \(soon.map(\.what).joined(separator: ", ")) working. Settings lists every subscription.")
                        .font(.system(size: F(22))).foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(S(28))
            .background(Color(red: 0.23, green: 0.16, blue: 0.03), in: RoundedRectangle(cornerRadius: S(20), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: S(20), style: .continuous).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
            .padding(.horizontal, Theme.sidePadding)
            .accessibilityElement(children: .combine)
        }
    }
}

/// In Settings: every subscription with its date (the PC checks IPTV itself; the others are entered on the PC).
struct SubscriptionsSection: View {
    @EnvironmentObject private var rtx: RTXServer

    var body: some View {
        Section {
            if rtx.subscriptions.isEmpty {
                Text(rtx.error == nil ? "Checking..." : "The PC isn't reachable.").foregroundStyle(.secondary)
            }
            ForEach(rtx.subscriptions) { s in
                VStack(alignment: .leading, spacing: S(6)) {
                    HStack {
                        Text(s.name).font(.headline)
                        Spacer()
                        Text(s.line).foregroundStyle(s.color)
                    }
                    Text(s.what).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, S(4))
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Subscriptions")
        } footer: {
            Text("Home warns 14 days before one runs out. The IPTV date comes from the provider; Newshosting and NZBgeek dates are kept on the PC.")
        }
    }
}

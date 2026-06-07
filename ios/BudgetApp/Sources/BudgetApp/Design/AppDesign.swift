import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) && !canImport(UIKit)
import AppKit
#endif

enum AppDesign {
    #if canImport(UIKit)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
    #elseif canImport(AppKit)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    #else
    static let background = Color.gray.opacity(0.08)
    static let panel = Color.white
    #endif

    static let tint = Color.accentColor
    static let positive = Color.green
    static let warning = Color.orange

    static func money(_ cents: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: cents.dollars)) ?? "$0.00"
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

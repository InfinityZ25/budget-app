import SwiftUI

struct ReceiptView: View {
    let transaction: Transaction

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Text(transaction.merchantName ?? transaction.description)
                        .font(.title2.weight(.semibold))
                    Text(AppDesign.money(transaction.amountCents))
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(transaction.locationName ?? transaction.source.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let lineItems = transaction.receiptLineItems, !lineItems.isEmpty {
                    section(title: "Receipt") {
                        ForEach(lineItems) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    if !item.quantity.isEmpty { Text(item.quantity).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(AppDesign.money(item.amountCents)).monospacedDigit()
                            }
                        }
                    }
                }

                if let splits = transaction.categorySplits, !splits.isEmpty {
                    section(title: "Splits") {
                        ForEach(splits) { split in
                            HStack {
                                Text(split.name)
                                Spacer()
                                Text(AppDesign.money(split.amountCents)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(AppDesign.background)
        .navigationTitle("Receipt")
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

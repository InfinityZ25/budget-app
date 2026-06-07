import SwiftUI

struct GoalsView: View {
    let goals: [Goal]

    var body: some View {
        NavigationStack {
            Group {
                if goals.isEmpty {
                    ContentUnavailableView("No Plans", systemImage: "flag", description: Text("Create savings goals or debt payoff plans from the Add sheet."))
                } else {
                    List(goals) { goal in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(goal.name, systemImage: goal.type == "debt_payoff" ? "creditcard.trianglebadge.exclamationmark" : "flag")
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(AppDesign.money(goal.targetCents - goal.currentCents))
                                    .font(.subheadline.weight(.semibold))
                            }
                            ProgressView(value: min(Double(max(0, goal.currentCents)), Double(max(1, goal.targetCents))), total: Double(max(1, goal.targetCents)))
                            Text("\(AppDesign.money(goal.currentCents)) of \(AppDesign.money(goal.targetCents))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Plans")
        }
    }
}

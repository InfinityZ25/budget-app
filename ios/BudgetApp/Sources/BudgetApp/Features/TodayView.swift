import SwiftUI

struct TodayView: View {
    @Bindable var store: FinanceStore
    @State private var showingAddData = false
    @State private var showingProfile = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MetricTile(title: "Net worth", value: AppDesign.money(store.netWorthCents), subtitle: "Across tracked accounts", systemImage: "sum")
                        MetricTile(title: "Spend", value: AppDesign.money(store.monthlySpendCents), subtitle: "This month", systemImage: "arrow.down.forward.circle")
                        MetricTile(title: "Available credit", value: AppDesign.money(store.availableCreditCents), subtitle: "Before utilization pressure", systemImage: "creditcard")
                        MetricTile(title: "Goals", value: String(store.goals.count), subtitle: "Active plans", systemImage: "sparkles")
                    }
                    accountsSection
                    upcomingSection
                }
                .padding(20)
            }
            .background(AppDesign.background)
            .navigationTitle("Budget")
	            .toolbar {
	                ToolbarItem(placement: .topBarLeading) {
	                    Button { showingProfile = true } label: {
	                        Image(systemName: "person.crop.circle")
	                            .font(.title3)
	                    }
	                    .accessibilityLabel("Profile")
	                }
	                ToolbarItemGroup(placement: .topBarTrailing) {
	                    Button { showingAddData = true } label: {
	                        Image(systemName: "plus")
	                    }
	                    Button { Task { await store.refresh() } } label: {
	                        Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
	                    }
	                }
	            }
            .sheet(isPresented: $showingAddData) {
                AddDataView(store: store)
            }
            .sheet(isPresented: $showingProfile) {
                ProfileView(store: store)
            }
        }
    }

	    private var header: some View {
	        let planningBalance = store.accounts.filter { $0.type != "credit" }.reduce(0) { $0 + $1.balanceCents }
	        return VStack(alignment: .leading, spacing: 8) {
	            Text("Available to plan")
	                .font(.subheadline.weight(.medium))
	                .foregroundStyle(.secondary)
	            Text(AppDesign.money(planningBalance))
	                .font(.system(size: 44, weight: .semibold, design: .rounded))
	                .contentTransition(.numericText())
            Text(store.errorMessage ?? "Cashflow, credit timing, and budgets in one place.")
                .font(.footnote)
                .foregroundStyle(store.errorMessage == nil ? Color.secondary : Color.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

	    private var accountsSection: some View {
	        VStack(alignment: .leading, spacing: 10) {
	            Text("Accounts").font(.headline)
	            if store.accounts.isEmpty {
	                ContentUnavailableView("No Accounts Connected", systemImage: "building.columns", description: Text("Open Profile to connect a real bank account with Plaid or add a manual account."))
	                    .padding(.vertical, 20)
	                    .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	            }
	            ForEach(store.accounts) { account in
                HStack(spacing: 12) {
	                    Image(systemName: icon(for: account))
	                        .frame(width: 32, height: 32)
	                        .background(.thinMaterial, in: Circle())
	                    VStack(alignment: .leading, spacing: 2) {
	                        Text(account.name).font(.body.weight(.medium))
	                        Text(account.source.capitalized).font(.caption).foregroundStyle(.secondary)
	                        if account.type == "credit", let close = account.statementCloseDay {
	                            Text("Closes day \(close)")
	                                .font(.caption2)
	                                .foregroundStyle(AppDesign.warning)
	                        }
	                    }
                    Spacer()
                    Text(AppDesign.money(account.balanceCents))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                .padding(14)
                .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

	    private var upcomingSection: some View {
	        VStack(alignment: .leading, spacing: 10) {
	            Text("Next decisions").font(.headline)
	            if store.goals.isEmpty {
	                ContentUnavailableView("No Plans Yet", systemImage: "flag", description: Text("Create a savings or debt payoff plan when you are ready."))
	                    .padding(.vertical, 20)
	                    .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	            }
	            ForEach(store.goals.prefix(2)) { goal in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(goal.name).font(.body.weight(.medium))
                        ProgressView(value: min(Double(max(0, goal.currentCents)), Double(max(1, goal.targetCents))), total: Double(max(1, goal.targetCents)))
                    }
                    Text(AppDesign.money(goal.targetCents - goal.currentCents))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(14)
                .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func icon(for account: Account) -> String {
        switch account.type {
        case "credit": "creditcard"
        case "investment": "chart.pie"
        default: "building.columns"
        }
    }
}

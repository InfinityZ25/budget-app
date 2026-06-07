import SwiftUI

struct RootView: View {
    @Bindable var store: FinanceStore

    var body: some View {
        TabView {
            TodayView(store: store)
                .tabItem { Label("Today", systemImage: "chart.line.uptrend.xyaxis") }
            TransactionsView(store: store)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
            CashflowView(store: store)
                .tabItem { Label("Cashflow", systemImage: "calendar.badge.clock") }
            BudgetsView(store: store)
                .tabItem { Label("Budgets", systemImage: "target") }
            MoreView(store: store)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .tint(.primary)
        .task { await store.refresh() }
    }
}

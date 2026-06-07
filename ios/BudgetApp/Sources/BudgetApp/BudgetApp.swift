import SwiftUI

@main
struct BudgetApp: App {
    @State private var store = FinanceStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}

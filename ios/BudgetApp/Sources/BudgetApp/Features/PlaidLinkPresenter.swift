import Foundation

#if canImport(LinkKit)
import LinkKit
import UIKit

@MainActor
@Observable
final class PlaidLinkPresenter {
    private var handler: Handler?

    func open(linkToken: String, onSuccess: @escaping (String) -> Void, onExit: @escaping (String) -> Void) {
        var configuration = LinkTokenConfiguration(token: linkToken) { success in
            onSuccess(success.publicToken)
        }
        configuration.onExit = { exit in
            if let error = exit.error {
                onExit(error.localizedDescription)
            } else {
                onExit("Plaid Link closed.")
            }
        }
        let result = Plaid.create(configuration)
        switch result {
        case let .failure(error):
            onExit(error.localizedDescription)
        case let .success(handler):
            self.handler = handler
            guard let presenter = UIApplication.shared.topMostViewController else {
                onExit("Unable to present Plaid Link.")
                return
            }
            handler.open(presentUsing: .viewController(presenter))
        }
    }
}

private extension UIApplication {
    var topMostViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .topMostPresentedViewController
    }
}

private extension UIViewController {
    var topMostPresentedViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topMostPresentedViewController
        }
        if let navigationController = self as? UINavigationController {
            return navigationController.visibleViewController?.topMostPresentedViewController ?? navigationController
        }
        if let tabBarController = self as? UITabBarController {
            return tabBarController.selectedViewController?.topMostPresentedViewController ?? tabBarController
        }
        return self
    }
}
#endif

import UIKit

final class SessionProposalRouter {
    weak var viewController: UIViewController!

    private let app: Application

    init(app: Application) {
        self.app = app
    }
    
    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.viewController.dismiss()
        }
    }
}

import ApplicationServices

enum WindowManageability: Equatable {
    case manageable
    case excluded
    /// A read failed, so the answer is not known yet.
    case unknown
}

/// Decides from a window's Accessibility attributes whether it is an ordinary window that can be
/// tiled. Minimized and fullscreen are not asked here: the WindowServer reports both.
enum WindowManageabilityPlanner {
    struct Inputs {
        var role: AXRead<String>
        var subrole: AXRead<String>
        var isModal: AXRead<Bool>
        var title: String?
        var positionSettable: AXRead<Bool>
        var sizeSettable: AXRead<Bool>
    }

    static func manageability(_ inputs: Inputs) -> WindowManageability {
        switch inputs.role {
        case .failed:
            return .unknown
        case .missing:
            return .excluded
        case .value(let role) where role != kAXWindowRole:
            return .excluded
        case .value:
            break
        }

        switch inputs.subrole {
        case .failed:
            return .unknown
        case .value(let subrole) where subrole != kAXStandardWindowSubrole:
            return .excluded
        case .value, .missing:
            break
        }

        switch inputs.isModal {
        case .failed:
            return .unknown
        case .value(true):
            return .excluded
        case .value(false), .missing:
            break
        }

        if isExcludedTitle(inputs.title) {
            return .excluded
        }

        for settable in [inputs.positionSettable, inputs.sizeSettable] {
            switch settable {
            case .failed:
                return .unknown
            case .value(false), .missing:
                return .excluded
            case .value(true):
                break
            }
        }

        return .manageable
    }

    static func isExcludedTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.localizedCaseInsensitiveContains("Picture in Picture") ||
            title.localizedCaseInsensitiveContains("Touch Bar")
    }
}

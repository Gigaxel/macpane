import CoreGraphics

enum FrameVerificationVerdict: Equatable {
    case applied
    case rejected
    case clamped(observedMinimum: CGSize)
}

enum FrameVerificationClassifier {
    static func classify(target: CGRect, observed: CGRect, tolerance: CGFloat) -> FrameVerificationVerdict {
        let originMatches = abs(observed.minX - target.minX) <= tolerance &&
            abs(observed.minY - target.minY) <= tolerance
        let widthMatches = abs(observed.width - target.width) <= tolerance
        let heightMatches = abs(observed.height - target.height) <= tolerance
        if originMatches, widthMatches, heightMatches {
            return .applied
        }

        let widthExceeds = observed.width > target.width + tolerance
        let heightExceeds = observed.height > target.height + tolerance
        let widthClampConsistent = widthMatches || widthExceeds
        let heightClampConsistent = heightMatches || heightExceeds
        if originMatches, widthExceeds || heightExceeds, widthClampConsistent, heightClampConsistent {
            return .clamped(observedMinimum: CGSize(
                width: widthExceeds ? observed.width : 0,
                height: heightExceeds ? observed.height : 0
            ))
        }

        return .rejected
    }
}

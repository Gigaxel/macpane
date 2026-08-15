import CoreGraphics
import Foundation

final class AppSizeConstraintsStore {
    private static let persistenceThreshold = 2
    private static let observationTolerance: CGFloat = 4

    private let defaults: UserDefaults
    private let defaultsKey = "learnedAppMinimumSizes"
    private var minimumSizesByBundleID: [String: CGSize]
    private var lastObservationByBundleID: [String: (size: CGSize, count: Int)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        minimumSizesByBundleID = Self.decode(defaults.dictionary(forKey: defaultsKey))
    }

    func minimumSize(forBundleIdentifier bundleID: String) -> CGSize? {
        guard let size = minimumSizesByBundleID[bundleID], size.width > 0 || size.height > 0 else {
            return nil
        }
        return size
    }

    func recordObservedMinimum(_ observed: CGSize, forBundleIdentifier bundleID: String, cappedTo cap: CGSize) {
        let capped = CGSize(
            width: min(max(observed.width, 0), max(cap.width, 0)),
            height: min(max(observed.height, 0), max(cap.height, 0))
        )
        guard capped.width > 0 || capped.height > 0 else { return }
        if let previous = lastObservationByBundleID[bundleID],
           Self.approximatelyEqual(previous.size, capped) {
            let count = previous.count + 1
            lastObservationByBundleID[bundleID] = (capped, count)
            if count >= Self.persistenceThreshold {
                let merged = Self.merged(minimumSizesByBundleID[bundleID], capped)
                guard minimumSizesByBundleID[bundleID] != merged else { return }
                minimumSizesByBundleID[bundleID] = merged
                save()
            }
        } else {
            lastObservationByBundleID[bundleID] = (capped, 1)
        }
    }

    func reset() {
        minimumSizesByBundleID.removeAll()
        lastObservationByBundleID.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }

    private func save() {
        var encoded: [String: [String: Double]] = [:]
        for (bundleID, size) in minimumSizesByBundleID {
            encoded[bundleID] = ["width": Double(size.width), "height": Double(size.height)]
        }
        defaults.set(encoded, forKey: defaultsKey)
    }

    private static func decode(_ raw: [String: Any]?) -> [String: CGSize] {
        guard let raw else { return [:] }
        var decoded: [String: CGSize] = [:]
        for (bundleID, value) in raw {
            guard let dimensions = value as? [String: Double] else { continue }
            let size = CGSize(
                width: CGFloat(dimensions["width"] ?? 0),
                height: CGFloat(dimensions["height"] ?? 0)
            )
            guard size.width > 0 || size.height > 0 else { continue }
            decoded[bundleID] = size
        }
        return decoded
    }

    private static func merged(_ existing: CGSize?, _ observed: CGSize) -> CGSize {
        CGSize(
            width: max(existing?.width ?? 0, observed.width),
            height: max(existing?.height ?? 0, observed.height)
        )
    }

    private static func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= observationTolerance &&
            abs(lhs.height - rhs.height) <= observationTolerance
    }
}

import CoreGraphics
import Foundation

final class AppSizeConstraintsStore {
    static let maximumPlausibleScreenFraction: CGFloat = 0.9
    static let undercutTolerance: CGFloat = 8
    static let undercutSightingInterval: TimeInterval = 0.25
    private static let persistenceThreshold = 2
    private static let observationTolerance: CGFloat = 4

    private let defaults: UserDefaults
    private let defaultsKey = "learnedAppMinimumSizes"
    private var minimumSizesByBundleID: [String: CGSize]
    private var lastObservationByBundleID: [String: (size: CGSize, count: Int)] = [:]
    private var undercutObservationsByWindow: [AnyHashable: (size: CGSize, count: Int, at: Date)] = [:]

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

    @discardableResult
    func recordObservedMinimum(
        _ observed: CGSize,
        forBundleIdentifier bundleID: String,
        screenSize: CGSize
    ) -> Bool {
        let observed = CGSize(width: max(observed.width, 0), height: max(observed.height, 0))
        guard observed.width > 0 || observed.height > 0 else { return false }
        guard Self.isPlausibleMinimum(observed, within: screenSize) else {
            lastObservationByBundleID.removeValue(forKey: bundleID)
            return false
        }
        if let previous = lastObservationByBundleID[bundleID],
           Self.approximatelyEqual(previous.size, observed) {
            let count = previous.count + 1
            lastObservationByBundleID[bundleID] = (observed, count)
            if count >= Self.persistenceThreshold {
                let merged = Self.merged(minimumSizesByBundleID[bundleID], observed)
                if minimumSizesByBundleID[bundleID] != merged {
                    setMinimum(merged, forBundleIdentifier: bundleID)
                }
            }
        } else {
            lastObservationByBundleID[bundleID] = (observed, 1)
        }
        return true
    }

    @discardableResult
    func recordObservedFrameSize(
        _ observed: CGSize,
        forBundleIdentifier bundleID: String,
        windowKey: AnyHashable,
        now: Date = Date()
    ) -> Bool {
        guard let learned = minimumSizesByBundleID[bundleID] else {
            undercutObservationsByWindow.removeValue(forKey: windowKey)
            return false
        }
        let undercutsWidth = Self.undercuts(learned.width, with: observed.width)
        let undercutsHeight = Self.undercuts(learned.height, with: observed.height)
        guard undercutsWidth || undercutsHeight else {
            undercutObservationsByWindow.removeValue(forKey: windowKey)
            return false
        }
        if let previous = undercutObservationsByWindow[windowKey],
           Self.approximatelyEqual(previous.size, observed) {
            guard now.timeIntervalSince(previous.at) >= Self.undercutSightingInterval else { return false }
            let count = previous.count + 1
            undercutObservationsByWindow[windowKey] = (observed, count, now)
            guard count >= Self.persistenceThreshold else { return false }
            undercutObservationsByWindow.removeValue(forKey: windowKey)
            lastObservationByBundleID.removeValue(forKey: bundleID)
            setMinimum(
                CGSize(width: undercutsWidth ? 0 : learned.width, height: undercutsHeight ? 0 : learned.height),
                forBundleIdentifier: bundleID
            )
            return true
        }
        undercutObservationsByWindow[windowKey] = (observed, 1, now)
        return false
    }

    @discardableResult
    func pruneImplausibleMinimums(within largestScreenSize: CGSize) -> Bool {
        var changed = false
        for (bundleID, learned) in minimumSizesByBundleID {
            let applicable = Self.applicableMinimum(learned, within: largestScreenSize)
            guard applicable != learned else { continue }
            setMinimum(applicable, forBundleIdentifier: bundleID)
            changed = true
        }
        return changed
    }

    func reset() {
        minimumSizesByBundleID.removeAll()
        lastObservationByBundleID.removeAll()
        undercutObservationsByWindow.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }

    static func isPlausibleMinimum(_ size: CGSize, within screenSize: CGSize) -> Bool {
        isPlausibleDimension(size.width, within: screenSize.width) &&
            isPlausibleDimension(size.height, within: screenSize.height)
    }

    static func applicableMinimum(_ learned: CGSize, within screenSize: CGSize) -> CGSize {
        CGSize(
            width: isPlausibleDimension(learned.width, within: screenSize.width) ? learned.width : 0,
            height: isPlausibleDimension(learned.height, within: screenSize.height) ? learned.height : 0
        )
    }

    private static func isPlausibleDimension(_ value: CGFloat, within extent: CGFloat) -> Bool {
        guard value > 0, extent > 0 else { return true }
        return value < extent * maximumPlausibleScreenFraction - 0.5
    }

    private static func undercuts(_ learned: CGFloat, with observed: CGFloat) -> Bool {
        learned > 0 && observed > 0 && observed < learned - undercutTolerance
    }

    private func setMinimum(_ size: CGSize, forBundleIdentifier bundleID: String) {
        if size.width > 0 || size.height > 0 {
            minimumSizesByBundleID[bundleID] = size
        } else {
            minimumSizesByBundleID.removeValue(forKey: bundleID)
        }
        save()
    }

    private func save() {
        var encoded: [String: [String: Double]] = [:]
        for (bundleID, size) in minimumSizesByBundleID {
            encoded[bundleID] = ["width": Double(size.width), "height": Double(size.height)]
        }
        if encoded.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(encoded, forKey: defaultsKey)
        }
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

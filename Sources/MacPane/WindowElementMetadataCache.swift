import ApplicationServices
import CoreGraphics
import Foundation

final class WindowElementMetadataCache {
    struct Entry {
        let element: AXUIElement
        var isStaticallyManageable = false
        var windowNumber: Int?
        var axIdentifier: String?
        var lastKnownFrame: CGRect?

        init(element: AXUIElement) {
            self.element = element
        }
    }

    private let lock = NSLock()
    private var entriesByKey: [WindowElementKey: Entry] = [:]
    private let maximumEntryCount = 800

    func entry(for key: WindowElementKey) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entriesByKey[key]
    }

    func update(_ key: WindowElementKey, element: AXUIElement, _ mutate: (inout Entry) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entry = entriesByKey[key] ?? Entry(element: element)
        mutate(&entry)
        entriesByKey[key] = entry
    }

    func entries(forPID pid: pid_t) -> [(key: WindowElementKey, entry: Entry)] {
        lock.lock()
        defer { lock.unlock() }
        return entriesByKey
            .filter { $0.key.pid == pid }
            .map { (key: $0.key, entry: $0.value) }
    }

    func removeEntry(for key: WindowElementKey) {
        lock.lock()
        entriesByKey.removeValue(forKey: key)
        lock.unlock()
    }

    func removeEntries(forPIDs pids: Set<pid_t>) {
        guard !pids.isEmpty else { return }
        lock.lock()
        entriesByKey = entriesByKey.filter { !pids.contains($0.key.pid) }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entriesByKey.removeAll()
        lock.unlock()
    }

    func pruneIfNeeded(keepingPIDs livePIDs: Set<pid_t>) {
        lock.lock()
        defer { lock.unlock() }
        guard entriesByKey.count > maximumEntryCount else { return }
        entriesByKey = entriesByKey.filter { livePIDs.contains($0.key.pid) }
    }
}

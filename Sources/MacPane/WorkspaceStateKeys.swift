enum WorkspaceStateKeys {
    static func nativeStateKeyComponent(of stateKey: String) -> String {
        guard let range = stateKey.range(of: ScreenInfo.workspaceStateSeparator) else { return stateKey }
        return String(stateKey[..<range.lowerBound])
    }

    static func displayKeyComponent(of stateKey: String) -> String {
        nativeStateKeyComponent(of: stateKey)
    }

    static func canMigrateState(from storedKey: String, to currentKey: String) -> Bool {
        guard storedKey != currentKey else { return true }
        guard displayKeyComponent(of: storedKey) == displayKeyComponent(of: currentKey) else { return false }
        let storedWorkspaceIndex = ScreenInfo.workspaceIndex(from: storedKey)
        let currentWorkspaceIndex = ScreenInfo.workspaceIndex(from: currentKey)
        return storedWorkspaceIndex == nil || currentWorkspaceIndex == nil || storedWorkspaceIndex == currentWorkspaceIndex
    }

    static func shouldRemoveStateAfterRestore(from storedKey: String, to currentKey: String) -> Bool {
        storedKey != currentKey && canMigrateState(from: storedKey, to: currentKey)
    }
}

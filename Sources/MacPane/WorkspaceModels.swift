import ApplicationServices
import CoreGraphics

enum DropAction {
    case swap
    case split(SnapDirection)
}
struct WorkspaceMenuState {
    let activeIndex: Int?
    let displayID: CGDirectDisplayID?
    let count: Int
    let maximumCount: Int
    let canDeleteActive: Bool
    let deleteBlockReason: String?
    var canCreateMore: Bool { count < maximumCount }
    var deleteWorkspaceTitle: String {
        if canDeleteActive {
            return "Delete Current Workspace"
        }
        if let deleteBlockReason {
            return "Delete Current Workspace (\(deleteBlockReason))"
        }
        return "Delete Current Workspace"
    }
    var statusText: String {
        guard let activeIndex else {
            return "Workspace: unavailable"
        }
        return "Workspace: \(activeIndex + 1)/\(count)"
    }
}
struct WorkspaceOverview {
    let displayID: CGDirectDisplayID?
    let displayName: String
    let activeWorkspaceIndex: Int
    let activeWorkspaceName: String?
    let workspaceCount: Int
    let items: [WorkspaceOverviewItem]
}
struct WorkspaceOverviewItem {
    let index: Int
    let name: String?
    let isActive: Bool
    let windows: [WorkspaceOverviewWindow]
}
struct WorkspaceOverviewWindow {
    let title: String
    let detail: String?
    let isFocused: Bool
}
struct WorkspaceContext {
    let screen: ScreenInfo
    let nativeStateKey: String
    let activeWorkspaceIndex: Int
    var stateKey: String {
        ScreenInfo.workspaceStateKey(nativeStateKey: nativeStateKey, workspaceIndex: activeWorkspaceIndex)
    }
    func withActiveWorkspaceIndex(_ index: Int) -> WorkspaceContext {
        WorkspaceContext(
            screen: ScreenInfo(
                key: screen.key,
                frame: screen.frame,
                displayID: screen.displayID,
                workspaceIndex: index
            ),
            nativeStateKey: nativeStateKey,
            activeWorkspaceIndex: index
        )
    }
}
struct WorkspaceSwitchIndicatorState {
    let workspaceIndex: Int
    let displayID: CGDirectDisplayID?
}
enum WorkspaceSlideDirection {
    case forward
    case backward
}
enum WorkspaceSlideEdge {
    case left
    case right
}
struct WorkspaceSlideTransition {
    let window: ManagedWindow
    let startFrame: CGRect
    let endFrame: CGRect
    let needsInitialFrame: Bool
}

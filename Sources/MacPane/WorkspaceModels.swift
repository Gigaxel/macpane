import ApplicationServices
import CoreGraphics

enum DropAction: Equatable {
    case swap
    case split(SnapDirection)
}
struct WorkspaceMenuState {
    let activeIndex: Int?
    let displayID: CGDirectDisplayID?
    let count: Int
    let maximumCount: Int
    let canDeleteActive: Bool
    var canCreateMore: Bool { count < maximumCount }
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
struct MonitorPickerOption {
    let displayID: CGDirectDisplayID?
    let name: String
    let isSource: Bool
}
struct WorkspaceOverviewItem {
    let index: Int
    let name: String?
    let isActive: Bool
    let screenFrame: CGRect
    let windows: [WorkspaceOverviewWindow]
}
struct WorkspaceOverviewWindow {
    let title: String
    let detail: String?
    let isFocused: Bool
    let frame: CGRect?
    let pid: pid_t
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

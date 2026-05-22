enum WorkspaceSwitchPlanResult {
    case unavailable
    case unchanged
    case planned(WorkspaceSwitchPlan)
}

struct WorkspaceSwitchPlan {
    let targetIndex: Int
    let visibleIndex: Int
    let activeContext: WorkspaceContext
    let indicator: WorkspaceSwitchIndicatorState
    let slideDirection: WorkspaceSlideDirection?

    var needsDeferredApply: Bool {
        slideDirection != nil
    }
}

struct WorkspaceSwitchApplyPlan {
    let nativeStateKey: String
    let visibleStateKey: String
    let targetStateKey: String
    let targetIndex: Int
    let stateKeys: Set<String>
}

enum WorkspaceSwitchPlanner {
    static func switchPlan(
        targetIndex: Int?,
        currentIndex: Int,
        visibleIndex: Int,
        context: WorkspaceContext,
        directionHint: Int?
    ) -> WorkspaceSwitchPlanResult {
        guard let targetIndex else { return .unavailable }
        guard targetIndex != currentIndex else { return .unchanged }

        let slideDirection = targetIndex == visibleIndex
            ? nil
            : WorkspaceSlidePlanner.direction(from: visibleIndex, to: targetIndex, hint: directionHint)

        return .planned(WorkspaceSwitchPlan(
            targetIndex: targetIndex,
            visibleIndex: visibleIndex,
            activeContext: context.withActiveWorkspaceIndex(targetIndex),
            indicator: WorkspaceSwitchIndicatorState(
                workspaceIndex: targetIndex,
                displayID: context.screen.displayID
            ),
            slideDirection: slideDirection
        ))
    }

    static func applyPlan(
        nativeStateKey: String,
        visibleIndex: Int,
        targetIndex: Int
    ) -> WorkspaceSwitchApplyPlan {
        let visibleStateKey = ScreenInfo.workspaceStateKey(
            nativeStateKey: nativeStateKey,
            workspaceIndex: visibleIndex
        )
        let targetStateKey = ScreenInfo.workspaceStateKey(
            nativeStateKey: nativeStateKey,
            workspaceIndex: targetIndex
        )
        return WorkspaceSwitchApplyPlan(
            nativeStateKey: nativeStateKey,
            visibleStateKey: visibleStateKey,
            targetStateKey: targetStateKey,
            targetIndex: targetIndex,
            stateKeys: [visibleStateKey, targetStateKey]
        )
    }
}

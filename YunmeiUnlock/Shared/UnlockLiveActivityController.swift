import ActivityKit

@available(iOS 16.1, *)
@MainActor
final class UnlockLiveActivityController {
    static let shared = UnlockLiveActivityController()

    private var activity: Activity<UnlockActivityAttributes>?

    func start() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        let attributes = UnlockActivityAttributes(lockName: "门锁")
        let state = UnlockActivityAttributes.ContentState(
            phase: .preparing,
            message: "准备连接门锁",
            isSuccessful: false
        )

        do {
            let content = ActivityContent(state: state, staleDate: nil)
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            activity = nil
        }
    }

    func update(phase: UnlockActivityAttributes.Phase, message: String) async {
        guard let activity else { return }

        let state = UnlockActivityAttributes.ContentState(
            phase: phase,
            message: message,
            isSuccessful: false
        )

        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end(success: Bool, message: String) async {
        guard let activity else { return }
        self.activity = nil

        let state = UnlockActivityAttributes.ContentState(
            phase: success ? .success : .failure,
            message: message,
            isSuccessful: success
        )

        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .immediate
        )
    }
}

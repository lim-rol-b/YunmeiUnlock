import ActivityKit

@available(iOS 16.1, *)
struct UnlockActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var phase: Phase
        var message: String
        var isSuccessful: Bool
    }

    enum Phase: String, Codable, Hashable {
        case preparing
        case scanning
        case connecting
        case discovering
        case writing
        case success
        case failure

        var title: String {
            switch self {
            case .preparing: return "准备中"
            case .scanning: return "扫描中"
            case .connecting: return "连接中"
            case .discovering: return "查找服务"
            case .writing: return "发送指令"
            case .success: return "已完成"
            case .failure: return "失败"
            }
        }

        var systemImageName: String {
            switch self {
            case .preparing, .scanning, .connecting, .discovering, .writing:
                return "lock.open"
            case .success:
                return "checkmark.circle.fill"
            case .failure:
                return "xmark.circle.fill"
            }
        }
    }

    var lockName: String = "门锁"
}

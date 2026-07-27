import Foundation

// MARK: - Models

struct Session {
    let display: String
    let sid: String
    let timestamp: TimeInterval
    let time: String
}

enum DisplayItem {
    case header(String)
    case session(Session, isActive: Bool, displayName: String)
}

struct StaleSession {
    let file: URL
    let pid: Int
    let staleSID: String
    let startedAt: TimeInterval
}

/// 一个 ~/.claude/jobs/<id>/ 下 state=="failed" 的僵死 daemon job。
/// 只收 state=="failed"——blocked（bg session 等输入的存活态）/ done / 运行中都不算（见 SessionScanner.scanFailedJobs）。
struct FailedJob {
    let jobId: String     // jobs/ 下的目录名
    let dir: URL          // ~/.claude/jobs/<jobId>/
    let name: String      // state.json 的 name（人看的标题），缺省 jobId
    let detail: String    // state.json 的 detail/intent 摘要，给确认对话框展示
    let sessionId: String // state.json 的 sessionId（完整 UUID），与 claude agents --json 的 sessionId 对齐，供只读存活探测
}

/// 送葬前对一个 failed job 的存活判定（基于 claude agents --json 只读探测）。
/// live：sessionId 仍在 live agents 列表 → 删目录会留孤儿，应走 `claude agents` 彻底停。
/// dead：不在 live 列表 → 残留可清，删目录安全。
/// unknown：探测不可用（claude 没找到/超时/解析失败）→ 降级，不对该 job 下存活断言。
enum JobLiveness {
    case live
    case dead
    case unknown
}

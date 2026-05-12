import Foundation

// MARK: - Shared Helpers

/// Convert a string to its Latin (pinyin for Chinese) + stripped diacritics form.
/// "Forge引擎" → "forgeyin qing"
func toLatin(_ s: String) -> String {
    let mutable = NSMutableString(string: s)
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    return (mutable as String).lowercased()
}

/// Extract the suffix after the first "-" in an instance ID (e.g. "forge-12345" → "12345").
/// Returns the full string if no "-" is found.
func instanceIdSuffix(_ id: String) -> String {
    id.split(separator: "-", maxSplits: 1).last.map(String.init) ?? id
}

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

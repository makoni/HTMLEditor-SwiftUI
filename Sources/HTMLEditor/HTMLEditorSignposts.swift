#if os(macOS)
import os

/// Signposts around the editor's main-thread work, so a trace says which part
/// of a keystroke is slow instead of leaving it to be inferred.
///
/// They cost nothing when no tool is listening, and they show up in Instruments
/// under the `os_signpost` instrument, on the "editing" category — record with
/// any template and add that instrument, or read the `os-signpost` table out of
/// the trace directly.
enum HTMLEditorSignpost {
    static let log = OSLog(subsystem: "com.reincubate.HTMLEditor", category: "editing")

    /// Wraps a block in a signposted interval.
    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () -> T) -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return body()
    }
}
#endif

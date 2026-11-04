import Foundation

/// Works out which project a log line belongs to.
///
/// A line's `cwd` is wherever the work was at the time, which can be a subfolder, even inside
/// `node_modules`. Claude Code names each log folder after the directory the session started in,
/// so the project is the nearest parent of `cwd` whose encoded path matches that folder name.
enum ProjectResolver {
    static func projectPath(cwd: String?, logFolderName: String) -> String {
        guard let cwd, !cwd.isEmpty else { return logFolderName }
        let root = stripWorktree(cwd)
        var candidate = root
        while candidate.count > 1 {
            if encode(candidate) == logFolderName { return candidate }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return root
    }

    static func encode(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            let isLetterOrDigit = scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar))
            return isLetterOrDigit ? Character(scalar) : "-"
        })
    }

    private static func stripWorktree(_ path: String) -> String {
        guard let range = path.range(of: "/.claude/worktrees/") else { return path }
        return String(path[..<range.lowerBound])
    }
}

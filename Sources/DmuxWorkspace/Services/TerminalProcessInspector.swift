import Foundation

struct TerminalProcessInspector: Sendable {
    func activeTool(forShellPID shellPID: Int32) -> String? {
        let snapshot = processSnapshot()
        guard !snapshot.isEmpty else {
            return nil
        }

        let rowsByPID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.pid, $0) })
        var childrenByParent: [Int32: [ProcessInfoRow]] = [:]
        for row in snapshot {
            childrenByParent[row.ppid, default: []].append(row)
        }

        let candidateRoots = candidateShellRoots(startingAt: shellPID, rowsByPID: rowsByPID)
        for rootPID in candidateRoots {
            if let tool = deepestToolMatch(rootPID: rootPID, childrenByParent: childrenByParent) {
                return tool
            }
        }
        return nil
    }

    func hasActiveCommand(forShellPID shellPID: Int32) -> Bool {
        let snapshot = processSnapshot()
        guard !snapshot.isEmpty else {
            return false
        }

        let rowsByPID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.pid, $0) })
        var childrenByParent: [Int32: [ProcessInfoRow]] = [:]
        for row in snapshot {
            childrenByParent[row.ppid, default: []].append(row)
        }

        let candidateRoots = candidateShellRoots(startingAt: shellPID, rowsByPID: rowsByPID)
        for rootPID in candidateRoots {
            if containsNonShellDescendant(rootPID: rootPID, childrenByParent: childrenByParent) {
                return true
            }
        }
        return false
    }

    private func deepestToolMatch(rootPID: Int32, childrenByParent: [Int32: [ProcessInfoRow]]) -> String? {
        var stack = childrenByParent[rootPID] ?? []
        var matches: [(depth: Int, tool: String)] = []
        var depthByPID: [Int32: Int] = [rootPID: 0]

        while let row = stack.popLast() {
            let parentDepth = depthByPID[row.ppid] ?? 0
            let depth = parentDepth + 1
            depthByPID[row.pid] = depth

            if let tool = detectTool(in: row.command) {
                matches.append((depth, tool))
            }

            stack.append(contentsOf: childrenByParent[row.pid] ?? [])
        }

        return matches.sorted { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.tool < rhs.tool
            }
            return lhs.depth > rhs.depth
        }.first?.tool
    }

    private func containsNonShellDescendant(rootPID: Int32, childrenByParent: [Int32: [ProcessInfoRow]]) -> Bool {
        var stack = childrenByParent[rootPID] ?? []

        while let row = stack.popLast() {
            if isShellCommand(row.command) || isLoginCommand(row.command) {
                stack.append(contentsOf: childrenByParent[row.pid] ?? [])
                continue
            }
            return true
        }

        return false
    }

    private func candidateShellRoots(startingAt shellPID: Int32, rowsByPID: [Int32: ProcessInfoRow]) -> [Int32] {
        var roots: [Int32] = []
        var currentPID: Int32? = shellPID
        var visited = Set<Int32>()

        while let pid = currentPID, pid > 0, visited.insert(pid).inserted {
            guard let row = rowsByPID[pid] else {
                break
            }
            if isShellCommand(row.command) {
                roots.append(pid)
            }

            guard let parent = rowsByPID[row.ppid] else {
                break
            }
            if isShellCommand(parent.command) || isLoginCommand(parent.command) {
                currentPID = parent.pid
            } else {
                break
            }
        }

        if roots.isEmpty {
            roots.append(shellPID)
        }
        return roots
    }

    private func detectTool(in command: String) -> String? {
        let normalized = command.lowercased()
        if normalized.contains("tool-wrapper.sh")
            || normalized.contains("/scripts/wrappers/bin/")
            || normalized.contains("/scripts/wrappers/tool-wrapper.sh") {
            return nil
        }

        for tool in ["claude-code", "claude", "codex", "opencode", "gemini"] {
            if normalized.contains("/\(tool)")
                || normalized.contains(" \(tool)")
                || normalized.contains(" \"\(tool)\"")
                || normalized.contains(" '\(tool)'")
                || normalized.hasPrefix("\(tool) ")
                || normalized == tool {
                return tool
            }
        }
        return nil
    }

    private func isShellCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        let shells = ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish", " -/bin/zsh", " -/bin/bash", " -/bin/sh"]
        return shells.contains(where: normalized.contains) || normalized.hasPrefix("-/bin/")
    }

    private func isLoginCommand(_ command: String) -> Bool {
        command.lowercased().contains("/usr/bin/login")
    }

    private func processSnapshot() -> [ProcessInfoRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-wwaxo", "pid=,ppid=,command="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: outputData, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    return nil
                }
                let parts = trimmed.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard parts.count == 3,
                      let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]) else {
                    return nil
                }
                return ProcessInfoRow(pid: pid, ppid: ppid, command: String(parts[2]))
            }
    }

    private struct ProcessInfoRow {
        var pid: Int32
        var ppid: Int32
        var command: String
    }
}

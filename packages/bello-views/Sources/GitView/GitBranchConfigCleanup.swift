import Foundation
import Darwin

extension GitService {
    /// The ref transaction has already succeeded. Cleanup is a separate,
    /// best-effort step and must never prompt a retry of the deletion itself.
    func removeDeletedBranchConfiguration(_ branch: GitBranchReference, in root: String) async -> String? {
        let retained = "Its local branch configuration was retained; review it in the terminal before reusing this name."
        do {
            let pattern = "^branch\\." + NSRegularExpression.escapedPattern(for: branch.name) + "\\.[^.]+$"
            let configured = try await run(["config", "--local", "--get-regexp", pattern], in: root)
            if configured.status == 1 { return nil }
            guard configured.status == 0 else { return retained }
            let storage = try await run(["config", "--local", "--get", "extensions.refStorage"], in: root)
            guard storage.status == 1 || (storage.status == 0 && storage.text.trimmingCharacters(in: .newlines) == "files") else { return retained }
            let common = try await branchCommand(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root).text.trimmingCharacters(in: .newlines)
            let components = branch.ref.split(separator: "/").map(String.init)
            guard components.count >= 3, components[0] == "refs", components[1] == "heads",
                  !components.contains(where: { $0 == "." || $0 == ".." }) else { return retained }
            // A deleted nested branch may leave no parent directory. Do not
            // recreate Git's shared directories or follow symlinked parents.
            var directory = common
            for component in [""] + components.dropLast() {
                if !component.isEmpty { directory += "/" + component }
                var info = stat()
                guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return retained }
            }
            let lockPath = common + "/" + branch.ref + ".lock"
            let fd = open(lockPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return retained }
            defer {
                var held = stat(), named = stat()
                if fstat(fd, &held) == 0, lstat(lockPath, &named) == 0,
                   held.st_dev == named.st_dev, held.st_ino == named.st_ino { unlink(lockPath) }
                close(fd)
            }
            // Holding the exact ref lock prevents Git from recreating this
            // branch while native git config obtains its own config lock.
            let exists = try await run(["show-ref", "--verify", "--quiet", branch.ref], in: root)
            guard exists.status == 1 else { return retained }
            let removed = try await run(["config", "--local", "--remove-section", "branch." + branch.name], in: root)
            if removed.status == 0 { return nil }
            // A missing section and a malformed/locked config can both be
            // fatal exits. Verify absence instead of accepting that exit code.
            let remaining = try await run(["config", "--local", "--get-regexp", pattern], in: root)
            return remaining.status == 1 ? nil : retained
        } catch { return retained }
    }
}

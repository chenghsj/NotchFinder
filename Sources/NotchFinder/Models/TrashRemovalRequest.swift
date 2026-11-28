import Darwin
import Foundation

struct TrashRemovalRequest: Sendable {
    struct Item: Sendable {
        let name: String
        let inode: ino_t
    }

    let directory: URL
    let device: dev_t
    let inode: ino_t
    let items: [Item]

    // Revalidate after a permission dialog or a trip to System Settings. New items,
    // restored files and replacements are outside the original confirmation.
    func remainingItems() throws -> [Item] {
        var root = stat()
        guard lstat(directory.path, &root) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard root.st_mode & S_IFMT == S_IFDIR, root.st_dev == device, root.st_ino == inode else { throw POSIXError(.ESTALE) }
        return try items.filter { item in
            guard !item.name.isEmpty, item.name != ".", item.name != "..",
                  !item.name.contains("/"), !item.name.contains("\0") else { throw POSIXError(.EINVAL) }
            var info = stat()
            if lstat(directory.appendingPathComponent(item.name, isDirectory: false).path, &info) != 0 {
                if errno == ENOENT { return false }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return info.st_dev == device && info.st_ino == item.inode
        }
    }

    // Both permission levels run the same transaction. The isolated system interpreter
    // can change its working directory to inspect a pinned directory without changing
    // the app's cwd. Every mutation uses the open directory descriptors.
    private static let removalScript = #"""
    ObjC.import('Foundation');
    const directoryFlags = \#(O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    ObjC.bindFunction('open', ['int', ['char *', 'int']]);
    ObjC.bindFunction('openat', ['int', ['int', 'char *', 'int']]);
    ObjC.bindFunction('mkdirat', ['int', ['int', 'char *', 'unsigned short']]);
    ObjC.bindFunction('renameatx_np', ['int', ['int', 'char *', 'int', 'char *', 'unsigned int']]);
    ObjC.bindFunction('removefileat', ['int', ['int', 'char *', 'void *', 'unsigned int']]);
    ObjC.bindFunction('unlinkat', ['int', ['int', 'char *', 'int']]);
    ObjC.bindFunction('fchdir', ['int', ['int']]);
    ObjC.bindFunction('flock', ['int', ['int', 'int']]);
    ObjC.bindFunction('geteuid', ['unsigned int', []]);
    ObjC.bindFunction('__error', ['int *', []]);
    ObjC.bindFunction('strerror', ['char *', ['int']]);

    function checked(result) {
        if (result >= 0) return result;
        const code = $.__error()[0];
        const error = new Error($.strerror(code));
        error.code = code;
        throw error;
    }

    function attributes(directory, name) {
        checked($.fchdir(directory));
        const values = $.NSFileManager.defaultManager.attributesOfItemAtPathError(name, null);
        return values.isNil() ? null : values;
    }

    function identity(values) {
        if (!values) return null;
        return values.objectForKey($.NSFileSystemNumber).stringValue.js + ':' +
               values.objectForKey($.NSFileSystemFileNumber).stringValue.js;
    }

    function move(from, name, to, target) {
        checked($.renameatx_np(from, name, to, target, \#(RENAME_EXCL)));
    }

    function run([path, rootID, ...pairs]) {
        const root = checked($.open(path, directoryFlags));
        if (identity(attributes(root, '.')) !== rootID) throw new Error('Trash directory changed');
        // A second instance must finish its batch before we claim any of its staging entries.
        checked($.flock(root, \#(LOCK_EX)));
        const stagingName = '.notchfinder-trash-' + $.NSUUID.UUID.UUIDString.js;
        try {
            checked($.mkdirat(root, stagingName, 0o700));
        } catch (error) {
            if (error.code !== \#(EACCES) && error.code !== \#(EPERM)) throw error;
            return JSON.stringify(pairs.filter((_, i) => i % 2 === 0)
                .map(name => ({name, code: error.code, message: error.message})));
        }
        const staging = checked($.openat(root, stagingName, directoryFlags));
        const values = attributes(staging, '.');
        if (values.objectForKey($.NSFileOwnerAccountID).unsignedIntValue !== $.geteuid() ||
            values.objectForKey($.NSFilePosixPermissions).unsignedIntValue !== 0o700) {
            throw new Error('Invalid staging directory');
        }
        const stagingID = identity(values);
        const failures = [];
        for (let i = 0; i < pairs.length; i += 2) {
            const name = pairs[i], expected = pairs[i + 1];
            if (!name || name === '.' || name === '..' || name.includes('/')) throw new Error('Invalid trash item');
            const original = attributes(root, name);
            if (original && identity(original) !== expected) continue;
            const claim = $.NSUUID.UUID.UUIDString.js;
            try {
                move(root, name, staging, claim);
            } catch (error) {
                if (error.code !== \#(ENOENT)) failures.push({name, code: error.code, message: error.message});
                continue;
            }
            try {
                const claimed = attributes(staging, claim);
                if (!claimed) throw new Error('Cannot identify ' + name);
                if (identity(claimed) === expected) {
                    checked($.removefileat(staging, claim, null, \#(REMOVEFILE_RECURSIVE)));
                    continue;
                }
            } catch (error) {
                failures.push({name, code: error.code || 0, message: error.message});
            }
            // A replacement won the claim, or deletion failed. Never overwrite a new entry.
            try {
                move(staging, claim, root, name);
            } catch (error) {
                const recovered = 'Recovered-' + claim;
                try {
                    move(staging, claim, root, recovered);
                } catch (restoreError) {
                    throw new Error(path + '/' + stagingName + '/' + claim + ': ' + restoreError.message);
                }
                failures.push({name, code: 0, message: path + '/' + recovered});
            }
        }
        if (identity(attributes(root, stagingName)) === stagingID) {
            checked($.unlinkat(root, stagingName, \#(AT_REMOVEDIR)));
        }
        return JSON.stringify(failures);
    }
    """#

    struct RemovalFailure: Decodable {
        let name: String
        let code: Int
        let message: String
    }

    private var batches: [[String]] {
        var result: [[String]] = []
        var arguments = [String]()
        var bytes = 0
        for item in items {
            let pair = [item.name, "\(device):\(item.inode)"]
            let size = pair.reduce(0) { $0 + $1.utf8.count + 2 }
            if bytes + size > 32 * 1024, !arguments.isEmpty {
                result.append(arguments)
                arguments = []
                bytes = 0
            }
            arguments += pair
            bytes += size
        }
        if !arguments.isEmpty { result.append(arguments) }
        return result
    }

    private func arguments(for batch: [String]) -> [String] {
        ["-l", "JavaScript", "-e", Self.removalScript, directory.path, "\(device):\(inode)"] + batch
    }

    func remove() throws -> [RemovalFailure] {
        try batches.flatMap { batch in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = arguments(for: batch)
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw LocalFileOperations.Failure(String(decoding: data, as: UTF8.self))
            }
            return try JSONDecoder().decode([RemovalFailure].self, from: data)
        }
    }

    var commands: [String] {
        batches.map { batch in
            "LC_ALL=C " + (["/usr/bin/osascript"] + arguments(for: batch))
                .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: " ")
        }
    }

    func removeWithAdministratorPrivileges() throws {
        guard directory.standardizedFileURL.path ==
                FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.standardizedFileURL.path else {
            throw POSIXError(.EPERM)
        }
        guard try !remainingItems().isEmpty else { return }
        let prompt = L10n.text("Notch Finder 需要管理員授權，才能刪除垃圾桶中剩餘的受保護項目。")
        let result = try Self.runAuthorizedCommands(commands, prompt: prompt)
        try checkResult(cancelled: result.cancelled, errors: result.errors)
    }

    func checkResult(cancelled: Bool, errors: [String]) throws {
        if cancelled {
            throw LocalFileOperations.Failure(L10n.text("已取消管理員授權，需要授權的項目仍在垃圾桶中。"))
        }
        let remaining = try remainingItems()
        guard !remaining.isEmpty else {
            if !errors.isEmpty { throw LocalFileOperations.Failure(errors.joined(separator: "\n")) }
            return
        }
        let message = L10n.text("macOS 未能刪除「%@」。", remaining[0].name)
        let denied = errors.contains { $0.contains("Operation not permitted") || $0.contains("Permission denied") }
        if denied {
            let pending = Self(directory: directory, device: device, inode: inode, items: remaining)
            throw LocalFileOperations.Failure(message, trashRecovery: pending)
        }
        throw LocalFileOperations.Failure(([message] + errors).joined(separator: "\n"))
    }

    private struct Result: Decodable {
        let cancelled: Bool
        let errors: [String]
    }

    private static func runAuthorizedCommands(_ commands: [String], prompt: String) throws -> Result {
        let script = """
        function run(argv) {
            ObjC.import('Foundation');
            const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
            const commands = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding)));
            const app = Application.currentApplication();
            app.includeStandardAdditions = true;
            const result = {cancelled: false, errors: []};
            for (const command of commands) {
                try {
                    const output = app.doShellScript(command, {administratorPrivileges: true, withPrompt: argv[0]});
                    for (const failure of JSON.parse(output)) result.errors.push(failure.name + ' (' + failure.message + ')');
                } catch (error) {
                    if (error.errorNumber === -128 || error.errorNumber === -60006) {
                        result.cancelled = true;
                        break;
                    }
                    result.errors.push(error.message);
                }
            }
            return JSON.stringify(result);
        }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, prompt]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let payload = try JSONEncoder().encode(commands)
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}

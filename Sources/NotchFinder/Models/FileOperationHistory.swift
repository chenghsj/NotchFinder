import Foundation
import Observation

@MainActor
@Observable
final class FileOperationHistory {
    enum Completion {
        case files(String?)
        case installed(from: FileBrowser.Destination, into: URL, warning: String?)
        case emptiedTrash(String?, TrashRemovalRequest?)

        var message: String? {
            switch self {
            case .files(let message), .installed(_, _, let message), .emptiedTrash(let message, _): message
            }
        }
    }

    @ObservationIgnored var deliver: ((Completion) -> Void)?
    private(set) var trashFailure: (message: String?, request: TrashRemovalRequest)?

    enum Direction: Sendable {
        case undo, redo

        func errorMessage(_ errors: [String]) -> String? {
            guard !errors.isEmpty else { return nil }
            let details = errors.joined(separator: "\n")
            return switch self {
            case .undo: L10n.text("無法完成復原\n%@", details)
            case .redo: L10n.text("無法完成重做\n%@", details)
            }
        }
    }

    @ObservationIgnored private var undoStack: [[FileReversal]] = []
    @ObservationIgnored private var redoStack: [[FileReversal]] = []
    private(set) var isRunning = false

    func canReplay(_ direction: Direction) -> Bool {
        !(direction == .undo ? undoStack : redoStack).isEmpty
    }

    typealias Operation = @MainActor () async -> Completion

    // A drop must reserve its place before asking an item provider to load URLs.
    func reserve(from origin: FileBrowser) -> (@MainActor (@escaping Operation) -> Void)? {
        guard !isRunning else { return nil }
        isRunning = true
        origin.showOperationMessage(nil)
        var started = false
        return { [self] operation in
            guard !started else { return }
            started = true
            Task {
                let result = await operation()
                finish(result, from: origin)
            }
        }
    }

    private func finish(_ result: Completion, from origin: FileBrowser) {
        if case .emptiedTrash(let message, let request) = result {
            trashFailure = request.map { (message, $0) }
        }
        isRunning = false
        if case .installed(let source, let applications, _) = result {
            origin.revealAfterInstall(from: source, into: applications)
        }
        if let deliver { deliver(result) }
        else { origin.receive(result) }
    }

    func clearTrashFailure() { trashFailure = nil }

    func perform(_ operation: @escaping @Sendable () throws -> [FileReversal]) async -> String? {
        let result = await Task.detached(priority: .userInitiated) {
            do { return (try operation(), nil as String?) }
            catch let error as LocalFileOperations.Failure { return (error.reversals, error.localizedDescription) }
            catch { return ([], error.localizedDescription) }
        }.value
        let (reversals, error) = result
        record(reversals)
        return error
    }

    func record(_ reversals: [FileReversal]) {
        guard !reversals.isEmpty else { return }
        undoStack.append(reversals)
        redoStack.removeAll()
    }

    func replay(_ direction: Direction) async -> String? {
        guard let batch = direction == .undo ? undoStack.popLast() : redoStack.popLast() else { return nil }
        let (remaining, reversed, errors) = await Task.detached(priority: .userInitiated) {
            var remaining = batch
            var reversed: [FileReversal] = []
            var errors: [String] = []
            while let step = remaining.last {
                do {
                    reversed.append(try step.reverse())
                    remaining.removeLast()
                } catch let error as FileReversal.MissingItem {
                    errors.append(error.localizedDescription)
                    remaining.removeLast()
                } catch {
                    errors.append("\(step.item.lastPathComponent)（\(error.localizedDescription)）")
                    break
                }
            }
            return (remaining, reversed, errors)
        }.value

        switch direction {
        case .undo:
            if !remaining.isEmpty { undoStack.append(remaining) }
            if !reversed.isEmpty { redoStack.append(reversed) }
        case .redo:
            if !remaining.isEmpty { redoStack.append(remaining) }
            if !reversed.isEmpty { undoStack.append(reversed) }
        }
        return direction.errorMessage(errors)
    }
}

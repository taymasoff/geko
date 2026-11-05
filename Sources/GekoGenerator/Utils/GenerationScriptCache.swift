import Foundation
import GekoCache
import GekoCore
import GekoSupport
import ProjectDescription
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Interface of the opt-in local execution cache for cache-profile target scripts.
protocol GenerationScriptCaching: AnyObject {
    func declaration(
        script: TargetScript,
        directory: AbsolutePath,
        environment: [String: String]
    ) -> GenerationScriptCache.Declaration?

    func prepare(
        script: TargetScript,
        identity: String,
        command: [String],
        directory: AbsolutePath,
        environment: [String: String]
    ) -> GenerationScriptCache.Invocation?

    func independent(
        _ invocations: [GenerationScriptCache.Invocation?],
        declarations: [GenerationScriptCache.Declaration?]?
    ) -> [GenerationScriptCache.Invocation?]

    func execute(
        _ invocation: GenerationScriptCache.Invocation?,
        run: () throws -> Void
    ) throws -> GenerationScriptCache.Outcome
}

/// An opt-in local execution cache for cache-profile target scripts. The script cache key
/// reuses `TargetScriptsContentHasher`; undeclared dependencies are a project concern and are
/// expected to be declared as script input paths.
final class GenerationScriptCache: GenerationScriptCaching {
    /// GEKO_CONFIG_ variables are excluded from manifest inputs, so on/off uses identical artifact keys.
    static let enabledEnvironmentKey = Constants.EnvironmentVariables.scriptCacheEnabled.rawValue

    /// Returns true when the script cache is enabled through the environment.
    static var isEnabled: Bool {
        Environment.shared.isScriptCacheEnabled
    }

    /// Returns a cache for the given workspace, or nil when the feature is off.
    static func make(
        workspacePath: AbsolutePath,
        cacheProfile: ProjectDescription.Cache.Profile
    ) -> GenerationScriptCaching? {
        guard isEnabled else { return nil }
        guard let storeDirectory = try? LogDirectoriesProvider().logDirectory(for: .generateMetadata) else {
            return nil
        }
        return GenerationScriptCache(
            workspacePath: workspacePath,
            cacheProfile: cacheProfile,
            storeDirectory: storeDirectory
        )
    }

    struct Invocation {
        let identity: String
        let command: [String]
        let directory: AbsolutePath
        let environment: [String: String]
        let inputs: [String]
        let toolInputs: [String]
        let outputs: [String]
        let script: TargetScript
    }

    struct Declaration {
        let inputs: [String]
        let outputs: [String]
    }

    enum Outcome: Equatable {
        case executed
        case skipped
        case ineligible
    }

    struct Entry: Codable {
        let path: String
        let kind: String
        let digest: String
    }

    struct Record: Codable {
        static let version = 1

        let version: Int
        let inputs: String
        let outputs: String
    }

    struct SharedSnapshot {
        let metadata: String
        let digest: String
    }

    /// Contains errors thrown while resolving or snapshotting declared cache dependencies.
    enum GenerationScriptCacheError: Error {
        case unsupportedPath(String)
    }

    // MARK: - Attributes

    private let workspacePath: AbsolutePath
    private let cacheProfile: ProjectDescription.Cache.Profile
    private let storePath: AbsolutePath
    private let fileManager = FileManager.default
    private let hasher = ContentHasher()
    private let targetScriptsHasher = TargetScriptsContentHasher(contentHasher: ContentHasher())
    private let storeLock = NSLock()
    private var records: [String: Record]
    private let snapshotLock = NSLock()
    private var rootSnapshots: [String: SharedSnapshot] = [:]

    // MARK: - Init

    init(
        workspacePath: AbsolutePath,
        cacheProfile: ProjectDescription.Cache.Profile,
        storeDirectory: AbsolutePath
    ) {
        self.workspacePath = workspacePath
        self.cacheProfile = cacheProfile
        storePath = storeDirectory.appending(component: Constants.GekoUserCacheDirectory.generateScriptHashesName)
        if let data = try? Data(contentsOf: storePath.url),
           let stored = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = stored
        } else {
            records = [:]
        }
    }

    // MARK: - GenerationScriptCaching

    /// Unsupported declarations execute normally. Opt-in alone never makes incomplete I/O cacheable.
    func prepare(
        script: TargetScript,
        identity: String,
        command: [String],
        directory: AbsolutePath,
        environment: [String: String]
    ) -> Invocation? {
        guard script.basedOnDependencyAnalysis != false,
              script.dependencyFile == nil
        else { return nil }

        do {
            guard let declaration = declaration(script: script, directory: directory, environment: environment) else { return nil }
            let inputs = declaration.inputs
            let outputs = declaration.outputs
            guard !inputs.isEmpty, !outputs.isEmpty else { return nil }
            // The shell is also a tool dependency; do not guess binaries hidden in arbitrary shell text.
            let toolInputs = [try resolve(script.shellPath, relativeTo: directory, environment: environment)]

            for toolInput in toolInputs where !fileManager.fileExists(atPath: toolInput) {
                logger.warning(
                    "Generation script cache: declared input \(toolInput) does not exist, cache disabled for \(script.name)"
                )
                return nil
            }

            for output in outputs {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: output, isDirectory: &isDirectory), isDirectory.boolValue {
                    return nil
                }
                guard !(inputs + toolInputs).contains(where: { contains($0, output) || contains(output, $0) }),
                      !contains(storePath.pathString, output),
                      !(inputs + toolInputs).contains(where: { contains($0, storePath.pathString) })
                else { return nil }
            }
            return Invocation(
                identity: identity, command: command, directory: directory, environment: environment,
                inputs: inputs, toolInputs: toolInputs, outputs: outputs, script: script
            )
        } catch {
            logger.debug("Generation script cache: declarations for \(script.name) are not cacheable: \(error)")
            return nil
        }
    }

    /// Inspect every scheduled script, including ones that are not eligible for caching.
    func declaration(script: TargetScript, directory: AbsolutePath, environment: [String: String]) -> Declaration? {
        do {
            var inputs = try script.inputPaths.files.map {
                try resolve($0.pathString, relativeTo: directory, environment: environment)
            }
            var outputs = try script.outputPaths.files.map {
                try resolve($0.pathString, relativeTo: directory, environment: environment)
            }
            for list in script.inputFileListPaths {
                let path = try resolve(list.pathString, relativeTo: directory, environment: environment)
                inputs.append(path)
                inputs += try readFileList(path, directory: directory, environment: environment)
            }
            for list in script.outputFileListPaths {
                let path = try resolve(list.pathString, relativeTo: directory, environment: environment)
                inputs.append(path)
                outputs += try readFileList(path, directory: directory, environment: environment)
            }
            return Declaration(inputs: Array(Set(inputs)).sorted(), outputs: Array(Set(outputs)).sorted())
        } catch {
            logger.debug("Generation script cache: cannot resolve I/O for \(script.name): \(error)")
            return nil
        }
    }

    /// Preserve normal execution for shared outputs or dependencies between concurrently scheduled scripts.
    func independent(_ invocations: [Invocation?], declarations: [Declaration?]? = nil) -> [Invocation?] {
        var result = invocations
        let declarations = declarations ?? invocations.map { invocation in
            invocation.map { Declaration(inputs: $0.inputs + $0.toolInputs, outputs: $0.outputs) }
        }
        // Unknown I/O cannot prove that an uncached writer will leave cached outputs alone.
        guard declarations.count == invocations.count, declarations.allSatisfy({ $0 != nil }) else {
            logger.warning(
                "Generation script cache: unresolved script declarations disable skipping for \(invocations.count) invocations"
            )
            return Array(repeating: nil, count: invocations.count)
        }
        for first in invocations.indices {
            guard let lhs = declarations[first] else { continue }
            for second in invocations.indices where second > first {
                guard let rhs = declarations[second] else { continue }
                let lhsInputs = lhs.inputs + (invocations[first]?.toolInputs ?? [])
                let rhsInputs = rhs.inputs + (invocations[second]?.toolInputs ?? [])
                let conflict = lhs.outputs.contains { output in
                    rhs.outputs.contains(output) || rhsInputs.contains { contains($0, output) }
                } || rhs.outputs.contains { output in
                    lhsInputs.contains { contains($0, output) }
                }
                if conflict {
                    result[first] = nil
                    result[second] = nil
                }
            }
        }
        return result
    }

    /// Only successful, stable inputs and the exact generated bytes publish a reusable record.
    func execute(_ invocation: Invocation?, run: () throws -> Void) throws -> Outcome {
        guard let invocation else {
            try run()
            return .ineligible
        }

        let inputHash: String
        do {
            inputHash = try fingerprint(invocation)
        } catch {
            logger.debug("Generation script cache: unavailable input snapshot for \(invocation.identity): \(error)")
            try run()
            return .ineligible
        }
        if matchesStoredRecord(invocation, inputHash: inputHash) {
            return .skipped
        }

        // A failed or interrupted execution must never retain a prior success record.
        removeRecord(invocation.identity)
        try run()
        if let after = try? fingerprint(invocation), after == inputHash,
           let outputs = try? outputFingerprint(invocation.outputs) {
            storeRecord(Record(version: Record.version, inputs: inputHash, outputs: outputs), for: invocation.identity)
        }
        return .executed
    }

    // MARK: - Store

    private func matchesStoredRecord(_ invocation: Invocation, inputHash: String) -> Bool {
        storeLock.lock()
        let record = records[invocation.identity]
        storeLock.unlock()
        guard let record, record.version == Record.version, record.inputs == inputHash else { return false }
        guard let outputs = try? outputFingerprint(invocation.outputs), outputs == record.outputs else { return false }
        // Brings skipped outputs' modification dates ahead of their inputs so Xcode's dependency
        // analysis does not rerun the corresponding build phases after generation.
        guard (try? refreshOutputModificationDates(invocation.outputs)) != nil else { return false }
        return true
    }

    private func removeRecord(_ identity: String) {
        storeLock.lock()
        let removed = records.removeValue(forKey: identity) != nil
        if removed {
            persistLocked()
        }
        storeLock.unlock()
    }

    private func storeRecord(_ record: Record, for identity: String) {
        storeLock.lock()
        records[identity] = record
        persistLocked()
        storeLock.unlock()
    }

    private func persistLocked() {
        do {
            try fileManager.createDirectory(at: storePath.removingLastComponent().url, withIntermediateDirectories: true)
            try encode(records).write(to: storePath.url, options: .atomic)
        } catch {
            logger.debug("Generation script cache store could not be saved: \(error)")
        }
    }

    // MARK: - Fingerprinting

    private func fingerprint(_ invocation: Invocation) throws -> String {
        // The house target-script hash covers declared I/O contents, name, tool, order and arguments.
        let (targetScriptHash, _) = try targetScriptsHasher.hash(
            targetScripts: [invocation.script],
            sourceRootPath: workspacePath,
            cacheProfile: cacheProfile
        )
        var strings = [
            targetScriptHash,
            invocation.command.joined(separator: "\n"),
        ]
        strings.append(contentsOf: invocation.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        for toolInput in invocation.toolInputs {
            strings.append(try hasher.hash(path: AbsolutePath(validating: toolInput)))
        }
        // Directory snapshots include member names, so renames inside an input directory invalidate.
        strings.append(try snapshot(invocation.inputs))
        return try hasher.hash(strings)
    }

    private func refreshOutputModificationDates(_ paths: [String]) throws {
        for path in paths {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        }
    }

    /// Inputs shared by every script (tool binaries, template trees) are memoized per run,
    /// guarded by change timestamps. Persisted records never trust file timestamps.
    private func snapshot(_ roots: [String]) throws -> String {
        var entries: [Entry] = []
        for root in roots {
            entries.append(Entry(path: root, kind: "root", digest: try memoizedSnapshot(root)))
        }
        return try hasher.hash(encode(entries))
    }

    private func memoizedSnapshot(_ path: String) throws -> String {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let metadata = try snapshot([path], metadataOnly: true)
        if let saved = rootSnapshots[path], saved.metadata == metadata { return saved.digest }
        let digest = try snapshot([path], metadataOnly: false)
        guard metadata == (try snapshot([path], metadataOnly: true)) else {
            throw GenerationScriptCacheError.unsupportedPath(path)
        }
        rootSnapshots[path] = SharedSnapshot(metadata: metadata, digest: digest)
        return digest
    }

    private func snapshot(_ roots: [String], metadataOnly: Bool) throws -> String {
        var entries: [Entry] = []
        for root in roots {
            try appendSnapshot(root, entries: &entries, metadataOnly: metadataOnly)
        }
        return try hasher.hash(encode(entries))
    }

    private func outputFingerprint(_ paths: [String]) throws -> String {
        for path in paths {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw GenerationScriptCacheError.unsupportedPath(path)
            }
        }
        return try snapshot(paths)
    }
}

// MARK: - Filesystem snapshots

private extension GenerationScriptCache {
    func appendSnapshot(_ path: String, entries: inout [Entry], metadataOnly: Bool) throws {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let kind = attributes[.type] as? FileAttributeType
        if kind == .typeDirectory {
            entries.append(Entry(path: path, kind: "directory", digest: ""))
            let children = try fileManager.contentsOfDirectory(atPath: path)
                .sorted()
                .filter { $0.uppercased() != ".DS_STORE" }
            for child in children {
                try appendSnapshot((path as NSString).appendingPathComponent(child), entries: &entries, metadataOnly: metadataOnly)
            }
        } else if kind == .typeRegular {
            let digest: String
            if metadataOnly {
                var attributes = stat()
                guard lstat(path, &attributes) == 0 else { throw GenerationScriptCacheError.unsupportedPath(path) }
                #if canImport(Darwin)
                let changed = "\(attributes.st_ctimespec.tv_sec):\(attributes.st_ctimespec.tv_nsec)"
                let modified = "\(attributes.st_mtimespec.tv_sec):\(attributes.st_mtimespec.tv_nsec)"
                #else
                let changed = "\(attributes.st_ctim.tv_sec):\(attributes.st_ctim.tv_nsec)"
                let modified = "\(attributes.st_mtim.tv_sec):\(attributes.st_mtim.tv_nsec)"
                #endif
                digest = "\(attributes.st_dev):\(attributes.st_ino):\(attributes.st_size):\(modified):\(changed)"
            } else {
                digest = try hasher.hash(Data(contentsOf: URL(fileURLWithPath: path)))
            }
            entries.append(Entry(path: path, kind: "file", digest: digest))
        } else {
            // Symlinks/special files need a separate dependency contract; execute conservatively.
            throw GenerationScriptCacheError.unsupportedPath(path)
        }
    }

    func readFileList(_ path: String, directory: AbsolutePath, environment: [String: String]) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { try resolve($0, relativeTo: directory, environment: environment) }
    }

    func resolve(_ value: String, relativeTo directory: AbsolutePath, environment: [String: String]) throws -> String {
        let regex = try NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$\(([A-Za-z_][A-Za-z0-9_]*)\)|\$([A-Za-z_][A-Za-z0-9_]*)"#)
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let key = (1..<match.numberOfRanges).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: value) else { return nil }
                return String(value[range])
            }.first
            guard let key, let replacement = environment[key], !replacement.isEmpty,
                  let range = Range(match.range, in: result)
            else { throw GenerationScriptCacheError.unsupportedPath(value) }
            result.replaceSubrange(range, with: replacement)
        }
        guard !result.isEmpty, !result.contains("$"),
              result.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[")) == nil
        else { throw GenerationScriptCacheError.unsupportedPath(value) }
        if result.hasPrefix("/") {
            return try AbsolutePath(validating: result).pathString
        }
        return try AbsolutePath(validating: result, relativeTo: directory).pathString
    }

    func contains(_ parent: String, _ child: String) -> Bool {
        parent == child || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

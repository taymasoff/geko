import Foundation
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

/// An opt-in local execution cache for cache-profile target scripts. Its configuration
/// file explicitly promises complete dependency declarations for every cached script name.
/// The experiment intentionally does not change artifact hashes or the manifest interface.
final class GenerationScriptCache: GenerationScriptCaching {
    /// GEKO_CONFIG_ variables are excluded from manifest inputs, so on/off uses identical artifact keys.
    static let configurationEnvironmentKey = Constants.EnvironmentVariables.experimentalScriptCache.rawValue

    /// Returns true when the experimental script cache is enabled through the environment.
    static var isEnabled: Bool {
        Environment.shared.generationScriptCacheConfigurationPath != nil
    }

    /// Returns an enabled cache for the given workspace, or nil when the feature is off or
    /// its configuration is unusable. A broken configuration disables the cache and never
    /// fails the generation.
    static func makeIfEnabled(workspacePath: AbsolutePath) -> GenerationScriptCaching? {
        guard let path = Environment.shared.generationScriptCacheConfigurationPath else { return nil }
        do {
            return try GenerationScriptCache(
                configurationPath: AbsolutePath(validating: path, relativeTo: FileHandler.shared.currentPath),
                workspacePath: workspacePath
            )
        } catch {
            logger.warning(
                "Generation script cache disabled: could not load configuration at \(path): \(error)"
            )
            return nil
        }
    }

    struct Invocation {
        let identity: String
        let command: [String]
        let directory: AbsolutePath
        let environment: [String: String]
        let inputs: [String]
        let sharedInputs: [String]
        let outputs: [String]
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

    struct Signature: Encodable {
        let version: Int
        let command: [String]
        let directory: String
        let environment: [String: String]
        let inputs: [String]
        let sharedInputs: [String]
        let outputs: [String]
    }

    struct Record: Codable {
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

    private let configuration: Configuration
    private let workspacePath: AbsolutePath
    private let cachePath: AbsolutePath
    private let fileManager = FileManager.default
    private let hasher = ContentHasher()
    private let snapshotLock = NSLock()
    private var sharedSnapshots: [String: SharedSnapshot] = [:]

    struct Configuration: Decodable {
        struct Policy: Decodable {
            let additionalInputs: [String]
        }
        let scripts: [String: Policy]
    }

    // MARK: - Init

    init(configurationPath: AbsolutePath, workspacePath: AbsolutePath) throws {
        configuration = try JSONDecoder().decode(
            Configuration.self,
            from: Data(contentsOf: configurationPath.url)
        )
        self.workspacePath = workspacePath
        cachePath = workspacePath.appending(components: ".geko", "GenerationScriptCache-v1")
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
        guard let policy = configuration.scripts[script.name],
              script.basedOnDependencyAnalysis != false,
              script.dependencyFile == nil
        else { return nil }

        do {
            guard let declaration = declaration(script: script, directory: directory, environment: environment) else { return nil }
            let inputs = declaration.inputs
            let outputs = declaration.outputs
            guard !inputs.isEmpty, !outputs.isEmpty else { return nil }
            var sharedInputs = try policy.additionalInputs.map {
                try resolve($0, relativeTo: workspacePath, environment: environment)
            }
            // The shell is also a tool dependency; do not guess binaries hidden in arbitrary shell text.
            sharedInputs.append(try resolve(script.shellPath, relativeTo: directory, environment: environment))
            sharedInputs = Array(Set(sharedInputs)).sorted()

            for sharedInput in sharedInputs where !fileManager.fileExists(atPath: sharedInput) {
                logger.warning(
                    "Generation script cache: declared input \(sharedInput) does not exist, cache disabled for \(script.name)"
                )
                return nil
            }

            for output in outputs {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: output, isDirectory: &isDirectory), isDirectory.boolValue {
                    return nil
                }
                guard !(inputs + sharedInputs).contains(where: { contains($0, output) || contains(output, $0) }),
                      !contains(cachePath.pathString, output),
                      !(inputs + sharedInputs).contains(where: { contains($0, cachePath.pathString) })
                else { return nil }
            }
            return Invocation(
                identity: identity, command: command, directory: directory, environment: environment,
                inputs: inputs, sharedInputs: sharedInputs, outputs: outputs
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
            invocation.map { Declaration(inputs: $0.inputs + $0.sharedInputs, outputs: $0.outputs) }
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
                let lhsInputs = lhs.inputs + (invocations[first]?.sharedInputs ?? [])
                let rhsInputs = rhs.inputs + (invocations[second]?.sharedInputs ?? [])
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

        let recordPath = cachePath.appending(component: try hasher.hash(invocation.identity) + ".json")
        let lock = FileLock(at: cachePath.appending(component: recordPath.basename + ".lock"))
        do {
            try fileManager.createDirectory(at: cachePath.url, withIntermediateDirectories: true)
            logger.debug("Generation script cache: acquiring record lock \(recordPath.basename)")
            try lock.lock()
        } catch {
            logger.debug("Generation script cache unavailable: \(error)")
            try run()
            return .ineligible
        }
        defer { lock.unlock() }

        guard let inputHash = try? fingerprint(invocation) else {
            logger.debug("Generation script cache: unavailable input snapshot for \(invocation.identity)")
            try? fileManager.removeItem(at: recordPath.url)
            try run()
            return .ineligible
        }
        if let data = try? Data(contentsOf: recordPath.url),
           let record = try? JSONDecoder().decode(Record.self, from: data),
           record.version == 1, record.inputs == inputHash,
           let outputs = try? outputFingerprint(invocation.outputs), outputs == record.outputs,
           (try? fingerprint(invocation)) == inputHash,
           (try? refreshOutputModificationDates(invocation.outputs)) != nil {
            return .skipped
        }

        // A failed or interrupted execution must never retain a prior success record.
        try? fileManager.removeItem(at: recordPath.url)
        try run()
        if let after = try? fingerprint(invocation), after == inputHash,
           let outputs = try? outputFingerprint(invocation.outputs) {
            do {
                let data = try encode(Record(version: 1, inputs: inputHash, outputs: outputs))
                try data.write(to: recordPath.url, options: .atomic)
            } catch {
                logger.debug("Generation script cache record could not be saved: \(error)")
            }
        }
        return .executed
    }

    // MARK: - Fingerprinting

    private func fingerprint(_ invocation: Invocation) throws -> String {
        let signature = Signature(
            version: 1, command: invocation.command, directory: invocation.directory.pathString,
            environment: invocation.environment, inputs: invocation.inputs,
            sharedInputs: invocation.sharedInputs, outputs: invocation.outputs
        )
        var entries = [Entry(path: "invocation", kind: "signature", digest: try hasher.hash(encode(signature)))]
        entries.append(Entry(path: "inputs", kind: "tree", digest: try snapshot(invocation.inputs)))
        for path in invocation.sharedInputs {
            entries.append(Entry(path: path, kind: "shared", digest: try sharedSnapshot(path)))
        }
        return try hasher.hash(encode(entries))
    }

    /// Memoization is in-memory only, guarded by current membership and nanosecond change timestamps.
    /// Resource and output bytes are always read; persisted records never trust file timestamps.
    private func sharedSnapshot(_ path: String) throws -> String {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let metadata = try snapshot([path], metadataOnly: true)
        if let saved = sharedSnapshots[path], saved.metadata == metadata { return saved.digest }
        let digest = try snapshot([path])
        guard metadata == (try snapshot([path], metadataOnly: true)) else {
            throw GenerationScriptCacheError.unsupportedPath(path)
        }
        sharedSnapshots[path] = SharedSnapshot(metadata: metadata, digest: digest)
        return digest
    }

    /// Brings skipped outputs' modification dates ahead of their inputs so Xcode's dependency
    /// analysis does not rerun the corresponding build phases after generation.
    private func refreshOutputModificationDates(_ paths: [String]) throws {
        for path in paths {
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        }
    }

    private func snapshot(_ roots: [String], metadataOnly: Bool = false) throws -> String {
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

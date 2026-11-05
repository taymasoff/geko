import Foundation
import GekoSupport
import GekoGraph
import GekoCore
import GekoCache
import ProjectDescription

public final class CacheTargetsPhaseScriptExecutionTask: CacheTask {
    struct TargetWithScripts {
        let graphTarget: GraphTarget
        let scripts: [TargetScript]
        
        var projectDirPath: AbsolutePath {
            AbsolutePath(stringLiteral: graphTarget.project.xcodeProjPath.dirname)
        }
    }
    
    struct PreparedScript {
        let shellPath: String
        let script: String
        let projectDirPath: AbsolutePath
        let env: [String: String]
        let originalScript: TargetScript
        let identity: String
        
        init(
            shellPath: String,
            script: String,
            projectDirPath: AbsolutePath,
            env: [String: SettingValue],
            originalScript: TargetScript,
            identity: String
        ) {
            self.shellPath = shellPath
            self.script = script
            self.projectDirPath = projectDirPath
            self.originalScript = originalScript
            self.identity = identity
            self.env = Dictionary(uniqueKeysWithValues: env.map { key, value in
                switch value {
                case let .string(stringValue):
                    return (key, stringValue)
                case let .array(arrayValue):
                    return (key, arrayValue.joined(separator: ","))
                }
            })
        }
        
        var command: [String] {
            var command = [shellPath, "-c"]
            // Change current execution directory to pbxproject location
            let script = """
            cd \(projectDirPath.pathString.spm_shellEscaped()) || exit $?
            \(script)
            """
            command.append(script)
            
            return command
        }
    }
    
    // MARK: - Attributes

    @Atomic var preparedScripts: [PreparedScript] = []
    private let clock: Clock
    private let timeTakenLoggerFormatter: TimeTakenLoggerFormatting
    private let makeScriptCache: (AbsolutePath, ProjectDescription.Cache.Profile) -> GenerationScriptCaching?

    // MARK: - Init

    public convenience init() {
        self.init(
            clock: WallClock(),
            timeTakenLoggerFormatter: TimeTakenLoggerFormatter(),
            makeScriptCache: GenerationScriptCache.make
        )
    }

    init(
        clock: Clock,
        timeTakenLoggerFormatter: TimeTakenLoggerFormatting,
        makeScriptCache: @escaping (AbsolutePath, ProjectDescription.Cache.Profile) -> GenerationScriptCaching?
    ) {
        self.clock = clock
        self.timeTakenLoggerFormatter = timeTakenLoggerFormatter
        self.makeScriptCache = makeScriptCache
    }
    
    // MARK: - CacheTask

    public func run(context: inout CacheContext) async throws {
        _preparedScripts.wrappedValue = []
        /// Dictionary, where the key is the name of the script, and the value is additional env for resolve
        let scriptEnvs = Dictionary(uniqueKeysWithValues: context.cacheProfile.scripts.map { ($0.name, $0.envKeys) })
        let enforceExplicitDependencies = context.config.generationOptions.enforceExplicitDependencies
        guard !scriptEnvs.isEmpty else { return }
        
        logger.info("Executing target shell scripts: \(scriptEnvs.keys.joined(separator: ", "))", metadata: .subsection)
        
        guard let graph = context.graph else {
            throw CacheTaskError.cacheContextValueUninitialized
        }
        
        let graphTraverser = GraphTraverser(graph: graph)
        graphTraverser.warmup()
        let targets = filterTargetsWithBuildPhaseScripts(
            graphTraverser: graphTraverser,
            scriptEnvs: scriptEnvs
        )
        let buildSettingsResolver = BuildSettingsResolver(
            graphTraverser: graphTraverser,
            projectDescriptorGenerator: ProjectDescriptorGenerator(enforceExplicitDependencies: enforceExplicitDependencies)
        )

        try targets.forEach(context: .concurrent) { target in
            try target.scripts.forEach(context: .concurrent) { script in
                if let shellScript = script.embeddedScript {
                    let (modifiedShellScript, env) = try replaceVariablesWithValues(
                        shellScript: shellScript,
                        target: target,
                        buildSettingsResolver: buildSettingsResolver
                    )
                    let additionalEnvironment = try resolveAdditionalEnv(
                        target: target,
                        scriptName: script.name,
                        scriptEnvs: scriptEnvs,
                        buildSettingsResolver: buildSettingsResolver
                    )
                    let mergedEnvironment = env.merging(additionalEnvironment) { $1 }
                    _preparedScripts.modify {
                        $0.append(
                            PreparedScript(
                                shellPath: script.shellPath,
                                script: modifiedShellScript,
                                projectDirPath: target.projectDirPath,
                                env: mergedEnvironment,
                                originalScript: script,
                                identity: identity(
                                    target: target,
                                    script: script,
                                    workspacePath: graph.workspace.path,
                                    profileName: context.cacheProfile.name
                                )
                            )
                        )
                    }
                }
            }
        }

        let cache = makeScriptCache(graph.workspace.path, context.cacheProfile)
        let timer = clock.startTimer()
        let scripts = _preparedScripts.wrappedValue
        let declarations = scripts.map { script in
            cache?.declaration(script: script.originalScript, directory: script.projectDirPath, environment: script.env)
        }
        let invocations = cache?.independent(scripts.map { script in
            cache?.prepare(
                script: script.originalScript, identity: script.identity, command: script.command,
                directory: script.projectDirPath, environment: script.env
            )
        }, declarations: declarations) ?? Array(repeating: nil, count: scripts.count)
        let counts = Atomic(wrappedValue: (skipped: 0, ineligible: 0))
        try Array(scripts.indices).forEach(context: .concurrent) { index in
            let script = scripts[index]
            let run = {
                _ = try System.shared.capture(script.command, verbose: false, environment: script.env)
            }
            if let cache {
                let outcome = try cache.execute(invocations[index], run: run)
                if outcome == .ineligible {
                    logger.debug("Generation script cache: executed ineligible invocation \(script.identity) (\(script.originalScript.name))")
                }
                counts.modify {
                    switch outcome {
                    case .skipped: $0.skipped += 1
                    case .ineligible: $0.ineligible += 1
                    case .executed: break
                    }
                }
            } else {
                try run()
            }
        }
        if let cache {
            let result = counts.wrappedValue
            logger.info(
                "Generation script cache: skipped \(result.skipped)/\(scripts.count), executed \(scripts.count - result.skipped), ineligible \(result.ineligible), \(timeTakenLoggerFormatter.timeTakenMessage(for: timer))",
                metadata: .subsection
            )
        } else if Environment.shared.isGenerateHashOnlyEnabled {
            logger.info(
                "Generation scripts: cache disabled, executed \(scripts.count), \(timeTakenLoggerFormatter.timeTakenMessage(for: timer))",
                metadata: .subsection
            )
        }
    }
    
    // MARK: - Helpers

    /// A record identity is stable across workspace relocations and distinguishes cache profiles,
    /// which resolve different script environments for the same target.
    func identity(
        target: TargetWithScripts,
        script: TargetScript,
        workspacePath: AbsolutePath,
        profileName: String
    ) -> String {
        let workspace = workspacePath.pathString
        let project = target.graphTarget.project.path.pathString
        let relativeProject = project.hasPrefix(workspace + "/")
            ? String(project.dropFirst(workspace.count + 1))
            : project
        let scriptIndex = target.graphTarget.target.scripts.firstIndex(of: script) ?? 0
        return "\(profileName)/\(relativeProject)/\(target.graphTarget.target.name)/\(scriptIndex)"
    }

    /// Filter available projects and scripts
    func filterTargetsWithBuildPhaseScripts(
        graphTraverser: GraphTraversing,
        scriptEnvs: [String: [String]]
    ) -> [TargetWithScripts] {
        var targets = [TargetWithScripts]()
        let internalTargets = graphTraverser.allInternalTargets()
        for target in internalTargets {
            let filteredShellScripts = target.target.scripts.filter { scriptEnvs.keys.contains($0.name) }
            guard !filteredShellScripts.isEmpty else { continue }
            targets.append(TargetWithScripts(
                graphTarget: target,
                scripts: filteredShellScripts
            ))
        }
        return targets
    }

    /// Cache profile provide scripts and additonal environment, this method resolve them
    func resolveAdditionalEnv(
        target: TargetWithScripts,
        scriptName: String,
        scriptEnvs: [String: [String]],
        buildSettingsResolver: BuildSettingsResolving
    ) throws -> [String: SettingValue] {
        guard let envKeys = scriptEnvs[scriptName] else { return [:] }
        var environment = [String: SettingValue]()
        try envKeys.forEach(context: .concurrent) { envKey in
            let resolvedVariable = try buildSettingsResolver.commonResolveBuildSetting(
                key: envKey,
                project: target.graphTarget.project,
                for: target.graphTarget.target,
                resolveAgaintsXCConfig: true
            )
            environment[envKey] = resolvedVariable
        }
        return environment
    }

    /// Method will be resolve and replace environment variables for provided script
    func replaceVariablesWithValues(
        shellScript: String,
        target: TargetWithScripts,
        buildSettingsResolver: BuildSettingsResolving,
        resolvedVariables: [String: SettingValue]? = nil
    ) throws -> (script: String, env: [String: SettingValue]) {
        let shellScriptRange = NSRange(location: 0, length: shellScript.utf16.count)
        let regex = BuildSettingsConstants.captureVariableInBuildConfigRegex
        let matches = regex.matches(in: shellScript, range: shellScriptRange)

        guard let match = matches.first else {
            // No variables left, return the value unchanged
            return (shellScript, resolvedVariables ?? [:])
        }

        var resolvedVariables = resolvedVariables ?? [:]
        var variableReference = ""
        var variable = ""

        for rangeIndex in 0 ..< match.numberOfRanges {
            let matchRange = match.range(at: rangeIndex)
            // Extract the substring matching the capture group
            if let substringRange = Range(matchRange, in: shellScript) {
                let capture = String(shellScript[substringRange])
                if capture.contains("$") {
                    variableReference = capture
                } else {
                    variable = capture
                }
            }
        }

        let resolvedVariable: SettingValue
        if let existedValue = resolvedVariables[variable] {
            resolvedVariable = existedValue
        } else {
            resolvedVariable = try buildSettingsResolver.commonResolveBuildSetting(
                key: variable,
                project: target.graphTarget.project,
                for: target.graphTarget.target,
                resolveAgaintsXCConfig: true
            )
            resolvedVariables[variable] = resolvedVariable
        }

        switch resolvedVariable {
        case let .string(stringValue):
            let updatedShellScript = shellScript.replacingOccurrences(of: variableReference, with: stringValue)
            return try replaceVariablesWithValues(
                shellScript: updatedShellScript,
                target: target,
                buildSettingsResolver: buildSettingsResolver,
                resolvedVariables: resolvedVariables
            )
        case let .array(arrayValue):
            let updatedShellScript = shellScript.replacingOccurrences(
                of: variableReference,
                with: arrayValue.joined(separator: ",")
            )
            return try replaceVariablesWithValues(
                shellScript: updatedShellScript,
                target: target,
                buildSettingsResolver: buildSettingsResolver,
                resolvedVariables: resolvedVariables
            )
        }
    }
}

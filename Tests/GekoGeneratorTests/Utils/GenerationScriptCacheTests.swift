import Foundation
import GekoCore
import GekoGraph
import GekoSupport
import GekoSupportTesting
import ProjectDescription
import XCTest
@testable import GekoGenerator

final class GenerationScriptCacheTests: GekoUnitTestCase {
    private var root: AbsolutePath!
    private var storeDirectory: AbsolutePath!
    private var cache: GenerationScriptCache!
    private var runs = 0

    override func setUp() {
        super.setUp()
        try! setUpFixture()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.url)
        super.tearDown()
    }

    private func setUpFixture() throws {
        root = try temporaryPath()
        try write("first", to: "input.txt")
        try write("template", to: "templates/main.stencil")
        try write("tool v1", to: "tools/generator")
        storeDirectory = root.appending(components: ".geko", "GenerateMetadata")
        cache = makeCache()
        runs = 0
    }

    private func makeCache() -> GenerationScriptCache {
        GenerationScriptCache(
            workspacePath: root,
            cacheProfile: ProjectDescription.Cache.Profile(name: "Development", configuration: "Debug", platforms: [:]),
            storeDirectory: storeDirectory
        )
    }

    private func write(_ contents: String, to path: String) throws {
        let url = root.appending(try RelativePath(validating: path)).url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func script(
        inputs: [String] = ["input.txt", "templates", "tools/generator"],
        output: String = "Generated/Resources.swift"
    ) -> TargetScript {
        .pre(
            script: "generator", name: "SwiftGen",
            inputPaths: .list(inputs.map { root.appending(try! RelativePath(validating: $0)) }),
            outputPaths: .list([root.appending(try! RelativePath(validating: output))]),
            basedOnDependencyAnalysis: true
        )
    }

    private func invocation(
        _ script: TargetScript? = nil,
        environment: [String: String] = [:],
        command: [String] = ["/bin/sh", "-c", "generator"],
        identity: String = "Project/Target/0"
    ) throws -> GenerationScriptCache.Invocation {
        try XCTUnwrap(cache.prepare(
            script: script ?? self.script(), identity: identity, command: command,
            directory: root, environment: environment
        ))
    }

    @discardableResult
    private func execute(_ invocation: GenerationScriptCache.Invocation? = nil) throws -> GenerationScriptCache.Outcome {
        try cache.execute(invocation ?? self.invocation()) {
            runs += 1
            try write("enum Resources {}", to: "Generated/Resources.swift")
        }
    }

    func test_make_whenEnvironmentIsUnset_returnsNil() {
        // Given / When
        let cache = GenerationScriptCache.make(
            workspacePath: root,
            cacheProfile: ProjectDescription.Cache.Profile(name: "Development", configuration: "Debug", platforms: [:])
        )

        // Then
        XCTAssertNil(cache)
    }

    func test_execute_whenRecordMatches_skipsAndRefreshesOutputModificationDate() throws {
        // Given
        XCTAssertEqual(try execute(), .executed)
        let output = root.appending(components: "Generated", "Resources.swift")
        let modified = try FileManager.default.attributesOfItem(atPath: output.pathString)[.modificationDate] as? Date
        cache = makeCache()
        try Thread.sleep(forTimeInterval: 0.05)

        // When
        let outcome = try execute()

        // Then
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(try String(contentsOf: output.url, encoding: .utf8), "enum Resources {}")
        let refreshed = try FileManager.default.attributesOfItem(atPath: output.pathString)[.modificationDate] as? Date
        XCTAssertNotNil(modified)
        XCTAssertGreaterThan(refreshed!, modified!)
    }

    func test_draftMapper_whenPreservationEnabled_survivesMaterializationAndRegeneratesMissingDraft() throws {
        // Given
        try execute()
        let output = root.appending(components: "Generated", "Resources.swift")
        var project = Project(name: "Project", targets: [
            Target(name: "Target", destinations: [.iPhone], product: .framework, preCreatedFiles: ["Generated/Resources.swift"])
        ])
        project.path = root
        var sideTable = ProjectSideTable()
        let mapper = CreateDraftFilesProjectMapper(preserveGeneratedDrafts: true)
        let effects = try mapper.map(project: &project, sideTable: &sideTable)
        try SideEffectDescriptorExecutor().execute(sideEffects: effects)
        XCTAssertTrue(project.targets[0].sources.contains { $0.paths.contains(output) })
        XCTAssertEqual(try execute(), .skipped)

        // When
        try FileManager.default.removeItem(at: output.url)
        let missingEffects = try mapper.map(project: &project, sideTable: &sideTable)
        try SideEffectDescriptorExecutor().execute(sideEffects: missingEffects)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.pathString))
        XCTAssertEqual(try execute(), .executed)
        XCTAssertEqual(runs, 2)
    }

    func test_draftMapper_whenPreservationDisabled_keepsStockTruncatingBehavior() throws {
        // Given
        try write("generated", to: "Generated/Resources.swift")
        var project = Project(name: "Project", targets: [
            Target(name: "Target", destinations: [.iPhone], product: .framework, preCreatedFiles: ["Generated/Resources.swift"])
        ])
        project.path = root
        var sideTable = ProjectSideTable()

        // When
        let effects = try CreateDraftFilesProjectMapper(preserveGeneratedDrafts: false)
            .map(project: &project, sideTable: &sideTable)
        try SideEffectDescriptorExecutor().execute(sideEffects: effects)

        // Then
        XCTAssertEqual(try String(contentsOf: root.appending(components: "Generated", "Resources.swift").url, encoding: .utf8), "")
    }

    func test_warmCache_whenPreservationEnabled_survivesDeferredDerivedCleanupAndDraftCreation() throws {
        // Given
        let relativeOutput = "Derived/Generated/Resources.swift"
        let output = root.appending(try RelativePath(validating: relativeOutput))
        let request = try invocation(script(output: relativeOutput))
        try cache.execute(request) { try write("enum Resources {}", to: relativeOutput) }

        for _ in 0..<3 {
            var project = Project(name: "Project", targets: [
                Target(name: "Target", destinations: [.iPhone], product: .framework, preCreatedFiles: [relativeOutput])
            ])
            project.path = root
            var workspace = WorkspaceWithProjects(workspace: Workspace(name: "Workspace", projects: [root]), projects: [project])
            var workspaceSideTable = WorkspaceSideTable()
            var projectSideTable = ProjectSideTable()

            // Real mapper ordering: cleanup is mapped first, but executes only after all mapping.
            let cleanup = try DeleteDerivedDirectoryWorkspaceMapper(preserveGeneratedDrafts: true)
                .map(workspace: &workspace, sideTable: &workspaceSideTable)
            let drafts = try CreateDraftFilesProjectMapper(preserveGeneratedDrafts: true)
                .map(project: &workspace.projects[0], sideTable: &projectSideTable)
            try SideEffectDescriptorExecutor().execute(sideEffects: cleanup + drafts)

            XCTAssertEqual(try String(contentsOf: output.url, encoding: .utf8), "enum Resources {}")
            XCTAssertTrue(workspace.projects[0].targets[0].sources.contains { $0.paths.contains(output) })
            XCTAssertEqual(try cache.execute(request) { XCTFail("Warm outputs must survive the complete side-effect batch") }, .skipped)
        }
    }

    func test_stockDrafts_whenDeletionPrecedesExecution_recreateAnEmptyPlaceholder() throws {
        // Given
        let relativeOutput = "Derived/Generated/Resources.swift"
        let output = root.appending(try RelativePath(validating: relativeOutput))
        try write("existing generated bytes", to: relativeOutput)
        var project = Project(name: "Project", targets: [
            Target(name: "Target", destinations: [.iPhone], product: .framework, preCreatedFiles: [relativeOutput])
        ])
        project.path = root
        var sideTable = ProjectSideTable()
        let drafts = try CreateDraftFilesProjectMapper(preserveGeneratedDrafts: false).map(project: &project, sideTable: &sideTable)
        let deletion = SideEffectDescriptor.directory(.init(path: root.appending(component: "Derived"), state: .absent))

        // When
        try SideEffectDescriptorExecutor().execute(sideEffects: [deletion] + drafts)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.pathString))
        XCTAssertEqual(try String(contentsOf: output.url, encoding: .utf8), "")
    }

    func test_executor_whenPresentWithoutContents_touchesAndTruncatesExistingFile() throws {
        // Given
        let output = root.appending(component: "input.txt")
        let executor = SideEffectDescriptorExecutor()

        // When
        try executor.execute(sideEffects: [.file(.init(path: output, state: .present))])

        // Then
        XCTAssertEqual(try String(contentsOf: output.url, encoding: .utf8), "")

        // And when explicit contents are provided
        try executor.execute(sideEffects: [.file(.init(path: output, contents: Data("replacement".utf8), state: .present))])
        XCTAssertEqual(try String(contentsOf: output.url, encoding: .utf8), "replacement")
    }

    func test_derivedCleanup_whenPreservationDisabled_stillRunsWithoutDraftsInsideThatTree() throws {
        for drafts in [[], ["Generated/Resources.swift"], ["DerivedOther/Resources.swift"], ["Derived/../Other/Resources.swift"]] {
            try write("stale", to: "Derived/old.txt")
            var project = Project(name: "Project", targets: [
                Target(name: "Target", destinations: [.iPhone], product: .framework, preCreatedFiles: drafts)
            ])
            project.path = root
            var workspace = WorkspaceWithProjects(workspace: Workspace(name: "Workspace", projects: [root]), projects: [project])
            var sideTable = WorkspaceSideTable()
            let effects = try DeleteDerivedDirectoryWorkspaceMapper(preserveGeneratedDrafts: false)
                .map(workspace: &workspace, sideTable: &sideTable)
            try SideEffectDescriptorExecutor().execute(sideEffects: effects)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(component: "Derived").pathString))
        }
    }

    func test_derivedCleanup_whenPreservationEnabled_preservesOnlyTreesWithDeclaredDrafts() throws {
        for (drafts, expectedDerived) in [([String](), false), (["Derived/Generated/Resources.swift"], true), (["DerivedOther/Resources.swift"], false)] {
            try write("stale", to: "Derived/old.txt")
            var project = Project(name: "Project", targets: [
                Target(name: "Target", destinations: [.iPhone], product: .framework, preCreatedFiles: drafts)
            ])
            project.path = root
            var workspace = WorkspaceWithProjects(workspace: Workspace(name: "Workspace", projects: [root]), projects: [project])
            var sideTable = WorkspaceSideTable()
            let effects = try DeleteDerivedDirectoryWorkspaceMapper(preserveGeneratedDrafts: true)
                .map(workspace: &workspace, sideTable: &sideTable)
            try SideEffectDescriptorExecutor().execute(sideEffects: effects)
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: root.appending(component: "Derived").pathString),
                expectedDerived
            )
        }
    }

    func test_spmCleanup_whenPreservationDisabled_stillPreservesOnlyModuleMaps() throws {
        try write("module Target {}", to: "Derived/Target.modulemap")
        try write("stale", to: "Derived/InfoPlists/Info.plist")
        var project = Project(name: "Project")
        project.path = root
        project.projectType = .spm
        var workspace = WorkspaceWithProjects(workspace: Workspace(name: "Workspace", projects: [root]), projects: [project])
        var sideTable = WorkspaceSideTable()
        let effects = try DeleteDerivedDirectoryWorkspaceMapper(preserveGeneratedDrafts: false)
            .map(workspace: &workspace, sideTable: &sideTable)
        try SideEffectDescriptorExecutor().execute(sideEffects: effects)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(components: "Derived", "Target.modulemap").pathString))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(components: "Derived", "InfoPlists").pathString))
    }

    func test_execute_whenInputBytesChangeEvenWithRestoredModificationTime_invalidates() throws {
        try execute()
        let path = root.appending(component: "input.txt").pathString
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
        try write("other", to: "input.txt")
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        XCTAssertEqual(try execute(), .executed)
        XCTAssertEqual(try execute(), .skipped)
        XCTAssertEqual(runs, 2)
    }

    func test_directoryMembership_whenAdditionRenameOrDeletionWithIdenticalBytes_invalidates() throws {
        try write("same", to: "Resources/One.txt")
        let request = try invocation(script(inputs: ["Resources"]))
        try execute(request)
        try write("same", to: "Resources/Two.txt")
        XCTAssertEqual(try execute(request), .executed)
        try FileManager.default.moveItem(at: root.appending(components: "Resources", "Two.txt").url, to: root.appending(components: "Resources", "Renamed.txt").url)
        XCTAssertEqual(try execute(request), .executed)
        try FileManager.default.removeItem(at: root.appending(components: "Resources", "One.txt").url)
        XCTAssertEqual(try execute(request), .executed)
        XCTAssertEqual(try execute(request), .skipped)
        XCTAssertEqual(runs, 4)
    }

    func test_directoryMembership_ignoresFinderMetadataFiles() throws {
        try write("same", to: "Resources/One.txt")
        let request = try invocation(script(inputs: ["Resources"]))
        XCTAssertEqual(try execute(request), .executed)
        try write("finder noise", to: "Resources/.DS_Store")
        XCTAssertEqual(try execute(request), .skipped)
    }

    func test_fingerprint_whenTemplatesToolEnvironmentOrCommandChange_invalidatesIndependently() throws {
        try execute()
        try write("changed template", to: "templates/main.stencil")
        XCTAssertEqual(try execute(), .executed)
        try write("tool v2", to: "tools/generator")
        XCTAssertEqual(try execute(), .executed)
        let environment = ["MASK_KEY": "private-key-must-not-be-saved"]
        XCTAssertEqual(try execute(invocation(environment: environment)), .executed)
        XCTAssertEqual(try execute(invocation(environment: environment, command: ["/bin/sh", "-c", "new-generator"])), .executed)
        let store = storeDirectory.appending(component: Constants.GekoUserCacheDirectory.generateScriptHashesName)
        let contents = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(contents.contains("private-key-must-not-be-saved"))
        XCTAssertEqual(runs, 5)
    }

    func test_prepare_whenShellIsMissing_disablesCachingForTheScript() throws {
        var action = script()
        action.shellPath = root.appending(component: "missing-shell").pathString

        XCTAssertNil(cache.prepare(script: action, identity: "id", command: [], directory: root, environment: [:]))
    }

    func test_execute_whenOutputDeletedModifiedOrTruncated_regenerates() throws {
        try execute()
        let output = root.appending(components: "Generated", "Resources.swift")
        try FileManager.default.removeItem(at: output.url)
        XCTAssertEqual(try execute(), .executed)
        try write("edited", to: "Generated/Resources.swift")
        XCTAssertEqual(try execute(), .executed)
        try write("", to: "Generated/Resources.swift")
        XCTAssertEqual(try execute(), .executed)
        XCTAssertEqual(try execute(), .skipped)
        XCTAssertEqual(runs, 4)
    }

    func test_execute_whenRunFailsAfterWritingOutputs_doesNotPublishOrRetainSuccess() throws {
        enum Failure: Error { case failed }
        try execute()
        try write("edited", to: "Generated/Resources.swift")
        XCTAssertThrowsError(try cache.execute(invocation()) {
            try write("enum Resources {}", to: "Generated/Resources.swift")
            throw Failure.failed
        })
        XCTAssertEqual(try execute(), .executed)
        XCTAssertEqual(try execute(), .skipped)
        XCTAssertEqual(runs, 2)
    }

    func test_execute_whenInputsChangeDuringExecution_doesNotPublish() throws {
        let outcome = try cache.execute(invocation()) {
            try write("enum Resources {}", to: "Generated/Resources.swift")
            try write("changed during generation", to: "input.txt")
        }
        XCTAssertEqual(outcome, .executed)
        XCTAssertEqual(try execute(), .executed)
        XCTAssertEqual(try execute(), .skipped)
    }

    func test_execute_whenStoreIsCorrupt_regenerates() throws {
        try execute()
        let store = storeDirectory.appending(component: Constants.GekoUserCacheDirectory.generateScriptHashesName)
        try "invalid JSON".write(to: store.url, atomically: true, encoding: .utf8)
        cache = makeCache()
        XCTAssertEqual(try execute(), .executed)
        XCTAssertEqual(try execute(), .skipped)
    }

    func test_fileLists_expandVariablesAndTrackBothListAndReferencedContents() throws {
        try write("# resources\n$(SRCROOT)/input.txt\n", to: "inputs.xcfilelist")
        try write("${SRCROOT}/Generated/Resources.swift\n", to: "outputs.xcfilelist")
        var action = script(inputs: [])
        action.inputFileListPaths = [root.appending(component: "inputs.xcfilelist")]
        action.outputFileListPaths = [root.appending(component: "outputs.xcfilelist")]
        let environment = ["SRCROOT": root.pathString]
        try execute(invocation(action, environment: environment))
        XCTAssertEqual(try execute(invocation(action, environment: environment)), .skipped)
        try write("new resource", to: "new.txt")
        try write("$(SRCROOT)/input.txt\n$SRCROOT/new.txt\n", to: "inputs.xcfilelist")
        XCTAssertEqual(try execute(invocation(action, environment: environment)), .executed)
        try write("changed resource", to: "new.txt")
        XCTAssertEqual(try execute(invocation(action, environment: environment)), .executed)
    }

    func test_prepare_whenDeclarationsAreIncompleteUnsupportedOrOverlapping_returnsNil() throws {
        var action = script(inputs: [])
        XCTAssertNil(cache.prepare(script: action, identity: "id", command: [], directory: root, environment: [:]))
        action = script()
        action.basedOnDependencyAnalysis = false
        XCTAssertNil(cache.prepare(script: action, identity: "id", command: [], directory: root, environment: [:]))
        action = script()
        action.dependencyFile = root.appending(component: "dependencies.d")
        XCTAssertNil(cache.prepare(script: action, identity: "id", command: [], directory: root, environment: [:]))
        action = script()
        action.inputPaths = .list([try AbsolutePath(validating: "/$(UNKNOWN)/input.txt")])
        XCTAssertNil(cache.prepare(script: action, identity: "id", command: [], directory: root, environment: [:]))
        action = script(inputs: ["Generated"])
        XCTAssertNil(cache.prepare(script: action, identity: "id", command: [], directory: root, environment: [:]))
        var executed = false
        XCTAssertEqual(try cache.execute(nil) { executed = true }, .ineligible)
        XCTAssertTrue(executed)
    }

    func test_execute_whenInputsAreSymlinks_executesWithoutReusingARecord() throws {
        try FileManager.default.createSymbolicLink(atPath: root.appending(component: "link.txt").pathString, withDestinationPath: "input.txt")
        let request = try invocation(script(inputs: ["link.txt"]))
        XCTAssertEqual(try execute(request), .ineligible)
        XCTAssertEqual(try execute(request), .ineligible)
        XCTAssertEqual(runs, 2)
    }

    func test_independent_whenOutputsOrDependenciesAreShared_disablesCachingForBothScripts() throws {
        let first = try invocation(identity: "first")
        let second = try invocation(identity: "second")
        XCTAssertTrue(cache.independent([first, second]).allSatisfy { $0 == nil })
        let dependent = try invocation(script(inputs: ["Generated/Resources.swift"], output: "Generated/Other.swift"), identity: "dependent")
        XCTAssertTrue(cache.independent([first, dependent]).allSatisfy { $0 == nil })
    }

    func test_independent_whenUncacheableWriterSharesOutput_disablesCachingForTheBatch() throws {
        let first = try invocation()
        var uncached = script()
        uncached.basedOnDependencyAnalysis = false
        let declarations = [
            cache.declaration(script: script(), directory: root, environment: [:]),
            cache.declaration(script: uncached, directory: root, environment: [:])
        ]
        XCTAssertTrue(cache.independent([first, nil], declarations: declarations).allSatisfy { $0 == nil })
    }

    func test_execute_whenInstancesRunConcurrently_completesAndLeavesAReusableRecord() throws {
        let request = try invocation()
        let other = makeCache()
        let state = Atomic(wrappedValue: (runs: 0, errors: [Error]()))
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                _ = try (index == 0 ? cache! : other).execute(request) {
                    state.modify { $0.runs += 1 }
                    Thread.sleep(forTimeInterval: 0.02)
                    try write("enum Resources {}", to: "Generated/Resources.swift")
                }
            } catch { state.modify { state in state.errors.append(error) } }
        }
        XCTAssertTrue(state.wrappedValue.errors.isEmpty)
        XCTAssertEqual(state.wrappedValue.runs, 2)
        XCTAssertEqual(try execute(), .skipped)
    }

    func test_execute_whenRecordedOutputIsLegitimatelyEmpty_canBeReused() throws {
        let request = try invocation()
        XCTAssertEqual(try cache.execute(request) { try write("", to: "Generated/Resources.swift") }, .executed)
        XCTAssertEqual(try cache.execute(request) { XCTFail("Empty output is valid when its recorded digest matches") }, .skipped)
    }
}

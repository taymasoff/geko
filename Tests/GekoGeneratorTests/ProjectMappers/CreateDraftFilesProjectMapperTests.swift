import Foundation
import GekoCore
import GekoGraph
import GekoGraphTesting
import GekoSupport
import ProjectDescription
import XCTest
@testable import GekoCoreTesting
@testable import GekoGenerator
@testable import GekoSupportTesting

final class CreateDraftFilesProjectMapperTests: GekoUnitTestCase {
    var subject: CreateDraftFilesProjectMapper!

    override public func setUp() {
        super.setUp()
        subject = CreateDraftFilesProjectMapper()
    }

    override public func tearDown() {
        subject = nil
        super.tearDown()
    }

    func test_map_returns_sideEffectsToCreateFiles() throws {
        // Given
        let projectA = Project.test(
            path: "/projectA",
            targets: [
                Target.test(preCreatedFiles: [
                    "Dummy/Dummy.swift",
                    "Dummy1.swift",
                    "DummyDir"
                ])
            ]
        )

        // When
        var project = projectA
        var sideTable = ProjectSideTable()
        let sideEffects = try subject.map(project: &project, sideTable: &sideTable)

        // Then
        let projectDir = projectA.path

        XCTAssertEqual(sideEffects, [
            .file(.init(path: projectDir.appending(component: "Dummy").appending(component: "Dummy.swift"), state: .present)),
            .file(.init(path: projectDir.appending(component: "Dummy1.swift"), state: .present)),
            .directory(.init(path: projectDir.appending(component: "DummyDir"), state: .present)),
        ])

        XCTAssertEqual(
            project.targets[0].sources,
            [
                SourceFiles(paths: [
                    projectDir.appending(components: ["Dummy", "Dummy.swift"]),
                    projectDir.appending(components: ["Dummy1.swift"])
                ])
            ]
        )
    }

    func test_map_whenPreservationEnabled_keepsExistingGeneratedDraftAsSource() throws {
        let root = try temporaryPath()
        let generated = root.appending(components: "Generated", "Resources.swift")
        try FileHandler.shared.createFolder(generated.parentDirectory)
        try FileHandler.shared.write("enum Resources {}", path: generated, atomically: true)
        var project = Project.test(path: root, targets: [Target.test(preCreatedFiles: ["Generated/Resources.swift"])])
        var sideTable = ProjectSideTable()

        let effects = try CreateDraftFilesProjectMapper(preserveGeneratedDrafts: true)
            .map(project: &project, sideTable: &sideTable)
        try SideEffectDescriptorExecutor().execute(sideEffects: effects)

        XCTAssertEqual(try FileHandler.shared.readTextFile(generated), "enum Resources {}")
        XCTAssertTrue(project.targets[0].sources.contains { $0.paths.contains(generated) })

        try FileHandler.shared.delete(generated)
        var freshProject = Project.test(path: root, targets: [Target.test(preCreatedFiles: ["Generated/Resources.swift"])])
        let missingEffects = try CreateDraftFilesProjectMapper(preserveGeneratedDrafts: true)
            .map(project: &freshProject, sideTable: &sideTable)
        try SideEffectDescriptorExecutor().execute(sideEffects: missingEffects)
        XCTAssertTrue(FileHandler.shared.exists(generated))
        XCTAssertEqual(try FileHandler.shared.readTextFile(generated), "")
        XCTAssertTrue(freshProject.targets[0].sources.contains { $0.paths.contains(generated) })
    }
}

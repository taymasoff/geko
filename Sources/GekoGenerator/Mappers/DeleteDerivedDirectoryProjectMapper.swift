import Foundation
import GekoCore
import GekoGraph
import GekoSupport
import ProjectDescription

/// A workspace mapper that returns side effects to delete the derived directory.
public final class DeleteDerivedDirectoryWorkspaceMapper: WorkspaceMapping {
    private let derivedDirectoryName: String
    private let fileHandler: FileHandling
    private let preserveGeneratedDrafts: Bool

    public init(
        derivedDirectoryName: String = Constants.DerivedDirectory.name,
        fileHandler: FileHandling = FileHandler.shared,
        preserveGeneratedDrafts: Bool = Environment.shared.generationScriptCacheConfigurationPath != nil
    ) {
        self.derivedDirectoryName = derivedDirectoryName
        self.fileHandler = fileHandler
        self.preserveGeneratedDrafts = preserveGeneratedDrafts
    }

    // MARK: - ProjectMapping

    public func map(
        workspace: inout WorkspaceWithProjects,
        sideTable: inout WorkspaceSideTable
    ) throws -> [SideEffectDescriptor] {
        var sideEffects: [SideEffectDescriptor] = []
        
        for i in 0 ..< workspace.projects.count {
            let project = workspace.projects[i]

            let projectSideEffects = try sideEffectDescriptors(for: project)

            sideEffects.append(contentsOf: projectSideEffects)
        }
        
        return sideEffects
    }

    private func sideEffectDescriptors(for project: Project) throws -> [SideEffectDescriptor] {
        logger.debug("Determining the /Derived directories that should be deleted within \(project.path)")
        let derivedDirectoryPath = project.path.appending(component: derivedDirectoryName)
        
        guard fileHandler.exists(derivedDirectoryPath) else {
            return []
        }

        // With the script cache enabled, these sources are generated before target hashing and
        // reused across warm generations. Deleting their parent tree would invalidate every warm
        // output before the gate runs. Without the cache the stock cleanup keeps running.
        if preserveGeneratedDrafts {
            let hasGeneratedDrafts = try project.targets.flatMap(\.preCreatedFiles).contains { file in
                let path = project.path.appending(try RelativePath(validatingRelativePath: file))
                return path == derivedDirectoryPath || path.isDescendant(of: derivedDirectoryPath)
            }
            if hasGeneratedDrafts {
                logger.debug("Preserving \(derivedDirectoryPath) for declared preCreatedFiles")
                return []
            }
        }
        
        // FIXME: Currently, the behavior for local spm packages differs from remote ones.
        // It would be great to either put all derived local packages into geko-derived or come up with a more elegant solution.
        if project.projectType == .spm {
            return try fileHandler.contentsOfDirectory(derivedDirectoryPath)
                .filter { $0.extension != "modulemap" }
                .map {
                    if fileHandler.isFolder($0) {
                        return .directory(DirectoryDescriptor(path: $0, state: .absent))
                    } else {
                        return .file(FileDescriptor(path: $0, state: .absent))
                    }
                }
        } else {
            return [.directory(DirectoryDescriptor(path: derivedDirectoryPath, state: .absent))]
        }
    }
}

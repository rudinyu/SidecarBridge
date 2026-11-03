# Dependency and attribution review

Reviewed on 2026-11-03 against source commit
`7e7fab01937fb5bf5d778336179c0f6adb87f9b8` and the retained macOS Build 136
Host and Viewer app bundles. This is a dependency inventory, not a grant of
rights for upstream code or a certification of every file's provenance.

## Findings

| Component | Evidence and use | License / required treatment |
| --- | --- | --- |
| SidecarBridge by yu314-coder | Upstream source incorporated into this fork; retained upstream ref `d1871bfeda3135a8c72843b5ad19b2961be60e76` | No standalone project license was found in that source. Do not describe the entire combined application as MIT-licensed without permission covering upstream code. |
| SidecarLauncher by Jovany Ocasio | Previously acknowledged research for native Sidecar connection techniques | MIT; copyright (c) 2023 Jovany Ocasio. Preserve the complete existing notice in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Current `Mac/SidecarConnector.swift` opens System Settings and does not load SidecarCore. |
| Apple frameworks and platform runtimes | App source imports and Build 136 dynamic-library references | Platform-provided components retain their own terms; the fork's MIT grant does not relicense them. See [Apple developer agreements](https://developer.apple.com/support/terms/). |
| XcodeGen 2.46.0 by Yonas Kolb | External project-generation tool used by build scripts, not an application library | MIT; copyright (c) 2018 Yonas Kolb. The installed tool includes its own LICENSE. It is not bundled in the reviewed Host or Viewer app. |
| Python and command-line build tools | Host-installed tools; Python scripts use standard-library modules | Build environment only. No vendored Python packages, Python runtime, or XcodeGen dependency libraries were found in the reviewed apps. Redistributing those tools would require a separate inventory of their own dependencies and notices. |

Primary license sources:

- [SidecarLauncher LICENSE](https://github.com/Ocasio-J/SidecarLauncher/blob/main/LICENSE)
- [XcodeGen 2.46.0 LICENSE](https://github.com/yonaskolb/XcodeGen/blob/2.46.0/LICENSE)
- [Upstream SidecarBridge](https://github.com/yu314-coder/SidecarBridge)

## Checks performed

- Read `project.yml`, `project.fork.yml`, and the tracked Xcode project.
  Dependencies name Apple SDK frameworks or local project targets; package
  product dependency lists in the tracked Xcode project are empty.
- Searched tracked files for Swift Package Manager, CocoaPods, and Carthage
  manifests/lockfiles, vendored frameworks, static/dynamic libraries, and fonts.
  None were found. This does not establish the origin of every source snippet.
- Inspected imports in `Mac/`, `MacViewer/`, `Pad/`, `Shared/`, and `Fork/`;
  found platform modules, with no external application-library imports.
- Inspected both architectures of each retained Build 136 executable using
  `otool -L`: Host has 42 unique library references and Viewer has 38. All are
  under `/System/Library/` or `/usr/lib/`. No additional Mach-O files were found
  inside either app bundle. These checks cannot independently rule out copied
  or statically incorporated source.
- Compared the preserved SidecarLauncher notice with its published MIT license
  and checked the locally installed XcodeGen 2.46.0 license.

## Open items before calling distribution fully licensed

1. Obtain or locate a license/permission covering the upstream SidecarBridge
   source. The MIT license added for original ScreenDock fork contributions
   does not resolve the upstream grant. A public GitHub repository alone is
   not an open-source license; see [GitHub's licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).
2. The reviewed Build 136 bundles contain neither LICENSE nor third-party notice
   files. Include the applicable license and attribution texts in future
   distributable packages before signing and notarization. This review does not
   alter the existing signed apps or archives.
3. Image assets are present, but no asset-specific license records were found.
   Their authorship and redistribution permission still need provenance
   confirmation; absence of a library dependency does not license image assets.
4. No iOS/iPadOS binary or transitive dependency inventory for redistributed
   development tools was audited. Recheck if dependencies, assets, or packaging
   change.

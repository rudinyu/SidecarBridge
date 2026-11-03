# Third-party notice

Dependency and binary inspection results, scope, and unresolved permissions are
recorded in [docs/DEPENDENCY_LICENSES.md](docs/DEPENDENCY_LICENSES.md).

## Upstream SidecarBridge

ScreenDock is a fork of SidecarBridge by yu314-coder:
https://github.com/yu314-coder/SidecarBridge

Upstream SidecarBridge code remains the work of its respective copyright
holders. The upstream source included in this checkout does not contain a
standalone project license. The MIT license in this fork's LICENSE file applies
only to original ScreenDock fork contributions by rudinyu and does not grant
rights to relicense upstream code.

## Platform frameworks and build tools

Apple frameworks and platform runtimes retain their own licensing terms and are
not covered by the ScreenDock fork's MIT license. The reviewed macOS Build 136
apps link platform-provided libraries; no external bundled library was found.

XcodeGen 2.46.0 is a build-time project generator, not an app dependency:
copyright (c) 2018 Yonas Kolb, licensed under MIT. Its installed distribution
includes its LICENSE. The original license is available at:
https://github.com/yonaskolb/XcodeGen/blob/2.46.0/LICENSE

XcodeGen and its dependencies are not bundled in the reviewed app binaries.
Redistributing build tools requires checking their own dependency notices.

## SidecarLauncher

The private Sidecar connection technique and selector names were informed by:

SidecarLauncher, copyright (c) 2023 Jovany Ocasio
https://github.com/Ocasio-J/SidecarLauncher

Licensed under the MIT License:

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

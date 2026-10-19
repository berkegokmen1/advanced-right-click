#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests build/ModuleCache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/ModuleCache" -target "$(uname -m)-apple-macos13.0" Sources/Actions.swift Sources/History.swift Sources/Archive.swift Sources/OutputNames.swift Sources/Operations.swift Tests/main.swift -o build/tests/operations -framework AppKit -framework ImageIO -framework PDFKit -framework Vision -framework AVFoundation -framework CoreText
build/tests/operations "$PWD/build/tests"
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/ModuleCache" -target "$(uname -m)-apple-macos13.0" Sources/Actions.swift Sources/ActionMenu.swift Sources/PreviewRange.swift Tests/Menu/main.swift -o build/tests/menu -framework AppKit
build/tests/menu "$PWD/build/tests"

#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
./scripts/swift.sh build
source .build/toolchain.env
extra=()
if [[ -n "$FIELDWORK_SWIFT_OVERLAY" ]]; then
    extra=(-vfsoverlay "$FIELDWORK_SWIFT_OVERLAY" -module-cache-path "$project_root/.build/fieldwork-module-cache")
fi
mkdir -p .build/checks
python3 - <<'PY'
import pathlib, re
source = pathlib.Path('Tests/ResearchCoreTests/ResearchCoreTests.swift').read_text()
names = re.findall(r'func (test\w+)\(\)', source)
entries = ',\n'.join('("'+name+'", { try $0.'+name+'() })' for name in names)
runner = '''import Foundation
@main struct CheckRunner {
 static func main() {
 let tests: [(String, (ResearchCoreTests) throws -> Void)] = [ENTRIES]
 for (name, run) in tests {
   let instance = ResearchCoreTests(), previous = checkFailures.count
   do { try instance.setUpWithError(); try run(instance) }
   catch { checkFailures.append(name + ": " + error.localizedDescription) }
   do { try instance.tearDownWithError() }
   catch { checkFailures.append(name + " cleanup: " + error.localizedDescription) }
   print((checkFailures.count == previous ? "PASS " : "FAIL ") + name)
 }
 for error in checkFailures { print(error) }
 print("\\(tests.count) checks, \\(checkFailures.count) failures")
 exit(checkFailures.isEmpty ? 0 : 1)
 }
}
'''.replace('ENTRIES', entries)
pathlib.Path('.build/checks/CheckRunner.swift').write_text(runner)
PY
swiftc -parse-as-library -D FIELDWORK_STANDALONE_CHECKS -I .build/debug/Modules \
    "${extra[@]}" Tests/Support/CheckSupport.swift \
    Tests/ResearchCoreTests/ResearchCoreTests.swift .build/checks/CheckRunner.swift \
    .build/debug/ResearchCore.build/*.swift.o -o .build/checks/ResearchChecks
.build/checks/ResearchChecks
python3 scripts/test-cli.py

swiftc -parse-as-library -I .build/debug/Modules \
    "${extra[@]}" Sources/Fieldwork/AppStore.swift Sources/Fieldwork/QuestionDragAndDrop.swift \
    Sources/Fieldwork/SpringLayout.swift Sources/Fieldwork/MarkdownSummary.swift Tests/FieldworkChecks/main.swift .build/debug/ResearchCore.build/*.swift.o \
    -o .build/checks/FieldworkChecks
.build/checks/FieldworkChecks

# Exercise real SwiftUI mouse gestures in a temporary offscreen window.
swiftc -parse-as-library -I .build/debug/Modules \
    "${extra[@]}" Sources/Fieldwork/AppStore.swift Sources/Fieldwork/ResearchLists.swift \
    Sources/Fieldwork/ListRow.swift Sources/Fieldwork/QuestionDragAndDrop.swift \
    Tests/FieldworkInteractionChecks/main.swift .build/debug/ResearchCore.build/*.swift.o \
    -o .build/checks/FieldworkInteractionChecks
.build/checks/FieldworkInteractionChecks
FIELDWORK_CHECK_MOTION=1 .build/checks/FieldworkInteractionChecks

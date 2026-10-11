#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
root="$PWD"
build=${INTENTION_BUILD_OUTPUT:-"$root/apps/macos/.build/app"}
app="$build/Intention.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
snapshot=$(mktemp -d /tmp/intention-build-source.XXXXXX)
trap 'rm -rf "$snapshot"' EXIT
cp -R apps/macos/Intention "$snapshot/Intention"
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find "$snapshot/Intention" -name '*.swift' -print0)
clang -c -fobjc-arc -mmacosx-version-min=14.0 "$snapshot/Intention/Platform/TextAccess/ColorMatching.m" -o "$snapshot/ColorMatching.o"
xcrun swiftc -import-objc-header "$snapshot/Intention/Platform/TextAccess/ColorMatching.h" "$snapshot/ColorMatching.o" -parse-as-library -module-name Intention -swift-version 6 \
  -target "$(uname -m)-apple-macos14.0" -D DEBUG -Onone \
  "${sources[@]}" -o "$app/Contents/MacOS/Intention"
for resource in "$snapshot"/Intention/Resources/*; do
  [[ $resource == */Info.plist ]] || cp "$resource" "$app/Contents/Resources/"
done
python3 - "$app/Contents/Info.plist" "$snapshot/Intention/Resources/Info.plist" <<'PY'
from pathlib import Path
import plistlib, re, sys
base=Path('apps/macos/Config')
values={}
for name in ['Shared.xcconfig','Debug.xcconfig','Local.xcconfig']:
    p=base/name
    if not p.exists(): continue
    for line in p.read_text().splitlines():
        m=re.match(r'^([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$',line)
        if m:values[m[1]]=m[2].replace('$()','')
# Identity is fixed, including when a local proxy origin is supplied.
values.update(PRODUCT_BUNDLE_IDENTIFIER='co.intention.mac',INTENTION_DISPLAY_NAME='Intention',EXECUTABLE_NAME='Intention')
origin=values.get('INTENTION_PROXY_URL','')
if origin:
    from urllib.parse import urlsplit
    u=urlsplit(origin)
    loopback = u.scheme == 'http' and u.hostname in ['localhost','127.0.0.1'] and u.port and 1 <= u.port <= 65535
    if (u.scheme != 'https' and not loopback) or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in ['', '/']:
        raise SystemExit('INTENTION_PROXY_URL must be HTTPS or an explicit loopback HTTP origin')
p=plistlib.loads(Path(sys.argv[2]).read_bytes())
def replace(v):
    if isinstance(v,str):return re.sub(r'\$\(([^)]+)\)',lambda m:values.get(m[1],''),v)
    if isinstance(v,list):return [replace(x) for x in v]
    if isinstance(v,dict):return {k:replace(x) for k,x in v.items()}
    return v
Path(sys.argv[1]).write_bytes(plistlib.dumps(replace(p)))
PY
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"

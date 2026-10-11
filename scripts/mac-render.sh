#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
app=apps/macos/Intention
build=${INTENTION_RENDER_BUILD:-/tmp/intention-evidence/render-build}
bundle="$build/SetupShots.app"
out=${1:-/tmp/intention-evidence/after}
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$out"
for resource in "$app"/Resources/*; do
  [[ $resource == */Info.plist ]] || cp "$resource" "$bundle/Contents/Resources/"
done
clang -dynamiclib -fblocks -mmacosx-version-min=14.0 -framework AppKit -framework AudioToolbox \
  apps/macos/Fixtures/Rendering/OffscreenRenderGuard.m -o "$build/libRenderGuard.dylib"
xcrun swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
  -D DEBUG -D OFFSCREEN_RENDER -Onone -L "$build" -lRenderGuard -Xlinker -rpath -Xlinker "$build" \
  "$app"/Onboarding/*.swift "$app"/Platform/Input/FnListenerHealth.swift "$app"/Look/*.swift \
  "$app"/Platform/Backend/AlphaClient.swift "$app"/Platform/Backend/AlphaSetupReply.swift \
  "$app"/Platform/Backend/AlphaMail.swift "$app"/Platform/Backend/MailAuthentication.swift \
  "$app"/Platform/Backend/DeviceKeyStore.swift "$app"/Platform/Panels/OwnHandMark.swift \
  "$app"/Platform/Audio/ProcessSafety.swift "$app"/App/AppLog.swift "$app"/App/DockActivationController.swift \
  apps/macos/Fixtures/Onboarding/SetupShots.swift apps/macos/Fixtures/Rendering/GuardedRender.swift \
  "$app"/Platform/Permissions/SettingsList.swift "$app"/Platform/Permissions/SettingsListReader.swift \
  "$app"/Platform/Permissions/SettingsPageTitles.swift "$app"/Platform/TextAccess/AccessibilityExecutor.swift \
  "$app"/Platform/TextAccess/AXElement.swift "$app"/Platform/TextAccess/FieldRange.swift \
  -o "$bundle/Contents/MacOS/SetupShots"
INTENTION_RENDER_GUARD=1 "$bundle/Contents/MacOS/SetupShots" --onboarding-snapshots "$out"
printf '%s\n' "$out"

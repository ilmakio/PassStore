#!/bin/bash
# Re-sign Sparkle.framework inner bundles WITHOUT the host app's sandbox entitlements.
# Xcode / SwiftPM can incorrectly propagate PassStore.entitlements to XPC services,
# which breaks AuthorizationRightSet (config.add.*.sparkle2-auth).
# See: https://sparkle-project.org/documentation/sandboxing/

set -euo pipefail

APP="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"

if [[ ! -d "$SPARKLE" ]]; then
  echo "note: Sparkle.framework not embedded, skipping resign-sparkle"
  exit 0
fi

SIGN="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [[ -z "$SIGN" || "$SIGN" == "-" ]]; then
  echo "note: no code signing identity, skipping resign-sparkle"
  exit 0
fi

if [[ -d "${SPARKLE}/Versions/B" ]]; then
  SV="${SPARKLE}/Versions/B"
elif [[ -d "${SPARKLE}/Versions/A" ]]; then
  SV="${SPARKLE}/Versions/A"
else
  echo "warning: Sparkle.framework has no Versions/A or B"
  exit 0
fi

echo "resign-sparkle: using identity ${SIGN} at ${SV}"

sign_runtime() {
  local target="$1"
  if [[ -e "$target" ]]; then
    echo "  codesign -f -s … -o runtime ${target}"
    /usr/bin/codesign -f -s "$SIGN" -o runtime "$target"
  fi
}

sign_runtime_preserve_entitlements() {
  local target="$1"
  if [[ -e "$target" ]]; then
    echo "  codesign … --preserve-metadata=entitlements ${target}"
    /usr/bin/codesign -f -s "$SIGN" -o runtime --preserve-metadata=entitlements "$target"
  fi
}

if [[ -d "${SV}/XPCServices" ]]; then
  shopt -s nullglob
  for xpc in "${SV}/XPCServices/"*.xpc; do
    name=$(basename "$xpc")
    if [[ "$name" == "Downloader.xpc" ]]; then
      sign_runtime_preserve_entitlements "$xpc"
    else
      sign_runtime "$xpc"
    fi
  done
  shopt -u nullglob
fi

sign_runtime "${SV}/Autoupdate"
sign_runtime "${SV}/Updater.app"
sign_runtime "$SPARKLE"

echo "resign-sparkle: done"

#!/bin/bash
# Builds the simulator into build/web, trimmed for static hosting under any
# path: local CanvasKit (no CDN), no service worker, no app AI models.
set -euo pipefail
cd "$(dirname "$0")"
flutter build web --release --no-web-resources-cdn --pwa-strategy=none
cd build/web
find canvaskit -name "*.symbols" -delete
# This app never loads the binary asset manifest or the shaders (checked in
# main.dart.js), and some static hosts refuse those file types.
rm -rf canvaskit/skwasm* canvaskit/wimp* flutter_service_worker.js .last_build_id \
  assets/packages/smart_eye assets/AssetManifest.bin assets/shaders
# Relative base so the page also works below a sub-path.
sed -i.bak 's#<base href="/">#<base href="./">#' index.html && rm index.html.bak
du -sh .

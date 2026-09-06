#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--snapshots" ) ]]; then
  echo "Usage: scripts/check-localization.sh [--snapshots]" >&2
  exit 2
fi

cd "$repo_root"
if [[ "${1:-}" == "--snapshots" ]]; then
  mkdir -p "$repo_root/.build/localization-audit"
  report_dir="$(mktemp -d "$repo_root/.build/localization-audit/run.XXXXXX")"
  export INKLET_LOCALIZATION_SNAPSHOT_DIR="$report_dir"
fi

for table in StoreSupport/InfoPlistStrings/*.lproj/InfoPlist.strings; do
  plutil -lint "$table"
done

swift test --filter Localization

if [[ "${1:-}" == "--snapshots" ]]; then
  python3 - "$report_dir" <<'PY'
import html
import json
import pathlib
import struct
import sys

folder = pathlib.Path(sys.argv[1])
images = sorted(folder.glob("*.png"))
if not images:
    raise SystemExit("No localization snapshots were generated.")
cards = []
for image in images:
    width, height = struct.unpack(">II", image.read_bytes()[16:24])
    metadata = image.with_suffix(".json")
    display_width = json.loads(metadata.read_text())["width"] if metadata.exists() else width
    name = html.escape(image.name, quote=True)
    cards.append(
        f'<figure><figcaption>{html.escape(image.stem)}</figcaption>'
        f'<a href="{name}"><img src="{name}" width="{int(display_width)}" '
        f'alt="{html.escape(image.stem, quote=True)}" loading="lazy"></a></figure>'
    )
page = '''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inklet localization audit</title>
<style>body{font:14px system-ui;margin:28px;background:#eee;color:#222}
main{display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start}
figure{margin:0;padding:16px;background:white;border-radius:10px;max-width:100%}
figcaption{margin-bottom:12px}img{height:auto;max-width:100%}</style>
<h1>Inklet localization audit</h1>
<p>Synthetic offscreen fixtures across all ten UI languages. Click an image for full resolution.
These images support visual review; passing tests do not certify every interaction or translation.</p><main>'''
(folder / "index.html").write_text(page + "\n".join(cards) + "</main></html>")
print(f"Localization gallery: {folder / 'index.html'} ({len(images)} snapshots)")
PY
fi

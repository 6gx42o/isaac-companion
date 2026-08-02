#!/usr/bin/env python3
"""Rebuild dev/preview.html from the real index.html.

Run this, plus the payload dump, to open the app's web UI in a browser:

    ISAAC_WEBDUMP=dev .build/debug/IsaacCompanionApp   # writes dev/payloads.js
    python3 dev/make-preview.py                        # writes dev/preview.html

The old preview.html was a hand-copied snapshot and had gone stale: index.html grew a
Play button, and app.js's top-level `$("play").addEventListener` threw against the
copy that lacked it -- which killed the whole script, so the preview rendered nothing.
Its sample data had drifted too, with cards and pills carrying no sprite and enemies
no art. Deriving both from the real page and the real bridge payloads means the
harness cannot disagree with the app it is supposed to be previewing.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / "Sources/IsaacCompanionApp/Web"
OUT = ROOT / "dev/preview.html"

html = (WEB / "index.html").read_text()

# Paths are relative to the page; the preview lives one directory over.
html = html.replace('href="style.css"', 'href="../Sources/IsaacCompanionApp/Web/style.css"')

BOOT = """<script>
  // Stand in for the native bridge: the page posts to it and expects answers back.
  window.webkit = { messageHandlers: { app: { postMessage: (m) => {
    if (m.type === "verdicts") setTimeout(() => window.onVerdicts(m.id, []), 0);
  } } } };
</script>
<script src="payloads.js"></script>
<script src="../Sources/IsaacCompanionApp/Web/app.js"></script>
<script>
  window.onAtlas(window.__ATLAS__);
  window.onStrip("pills", window.__PILLS__);
  window.onCatalogue(window.__CATALOGUE__);
  window.onState(window.__STATE__);
  window.onAchievements(window.__ACH__);
  window.onBestiary(window.__BEST__);
  // The bridge sends these just after first paint; the preview does it up front so
  // the enemy and badge art is there without a tab click.
  for (const n of ["achievements", "monsters"]) window.onIconAtlas(n, window.__ICONS__[n]);
</script>
"""

html, n = re.subn(r'<script src="app\.js"></script>', BOOT, html)
assert n == 1, f"expected one app.js script tag, found {n}"
OUT.write_text(html)
print("wrote", OUT, len(html), "bytes")

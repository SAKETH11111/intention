#!/bin/sh
# Check the static site for tracking, network calls, external URLs in site code, non-synthetic
# email addresses and broken local references. Exits non-zero on a finding.
#
# Identifiers that must never appear (private names and hosts) are not kept in this repository.
# Pass a private rules file to also run them through scripts/check-public.py:
#   sh scripts/site-check.sh --rules /path/to/private-rules.json
cd "$(dirname "$0")/../site" || exit 2
status=0
fail() { echo "FAIL: $1"; status=1; }

grep -rnIi '/Users/\|sourceMappingURL' . && fail 'local paths or source maps'
grep -rnIi 'posthog\|gtag\|sentry\|plausible\|segment\.\|fetch(\|sendBeacon\|XMLHttpRequest\|WebSocket' . && fail 'telemetry or network calls'
grep -rnIoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' . | grep -v '@example\.com' | grep -vE '@[0-9]x\.(webp|png|avif)$' && fail 'non-synthetic email address'

# External URLs are allowed only in license and credit text, never in pages, styles or scripts.
grep -rnIoE 'https?://[^ "<>)]+' --include='*.html' --include='*.css' --include='*.js' --include='*.json' . | grep -v 'http://www.w3.org/' && fail 'external URL in site code'

# Local references resolve.
python3 -I - <<'PY' || status=1
import pathlib, re, sys
from urllib.parse import urljoin, urlparse
root = pathlib.Path('.').resolve()
bad = 0
for f in list(root.rglob('*.html')) + list(root.rglob('*.css')) + list(root.rglob('*.js')):
    text = f.read_text()
    refs = re.findall(r'(?:href|src)="([^"#][^"]*)"', text) + re.findall(r"url\(\s*['\"]?([^'\")]+)", text)
    refs += re.findall(r"new URL\('([^']+)'", text)
    rel = f.relative_to(root).as_posix()
    # Scripts resolve paths against the page (the site root); pages and styles against themselves.
    base = 'http://site/' + ('index.html' if f.suffix == '.js' else rel)
    for r in refs:
        if r.startswith(('http:', 'https:', 'data:', 'mailto:', '#')) or r.endswith('/') and f.suffix == '.js': continue
        path = urlparse(urljoin(base, r)).path.lstrip('/')
        p = root / path
        if p.is_dir() or path == '': p = p / 'index.html'
        if not p.exists():
            print(f'FAIL: {rel} -> {r} missing'); bad = 1
sys.exit(bad)
PY

if [ "$1" = "--rules" ] && [ -n "$2" ]; then
  python3 ../scripts/check-public.py --rules "$2" || status=1
fi
[ $status = 0 ] && echo "site-check: clean"
exit $status

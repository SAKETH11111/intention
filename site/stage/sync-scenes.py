#!/usr/bin/env python3
"""Copy scenes.json into index.html's <script id="stage-scenes"> block, so the page needs no fetch.
Run after editing scenes.json: python3 site/stage/sync-scenes.py"""
import json, pathlib, re
here = pathlib.Path(__file__).resolve().parent
data = json.dumps(json.loads((here / 'scenes.json').read_text()), ensure_ascii=False, indent=1).replace('</', '<\\/')
page = here / 'index.html'
html = page.read_text()
block = f'<script id="stage-scenes" type="application/json">\n{data}\n</script>'
html, n = re.subn(r'<script id="stage-scenes" type="application/json">.*?</script>', lambda m: block, html, flags=re.S)
if n != 1:
    html = html.replace('  <script src="stage.js" defer></script>', block + '\n  <script src="stage.js" defer></script>', 1)
page.write_text(html)
print('scenes.json embedded in index.html')

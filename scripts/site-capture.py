#!/usr/bin/env python3
"""Capture comparable screenshots and a short hero video of a locally served site.

Usage: python3 scripts/site-capture.py <base-url> <out-dir>

Both sides of a before/after comparison use the same sizes and states:
desktop 1440x900 and phone 390x844, hero viewport with motion, full page
with reduced motion (each section as a still), and the waitlist form after a
synthetic submission. External requests are blocked so nothing leaves the machine.
"""
import pathlib
import sys

from playwright.sync_api import sync_playwright

base, out = sys.argv[1].rstrip("/"), pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
SIZES = {"desktop": (1440, 900), "phone": (390, 844)}


problems = []


def local_only(route):
    url = route.request.url
    if url.startswith(base) or url.startswith("data:"):
        route.continue_()
    else:
        problems.append(f"blocked external request: {url}")
        route.abort()


def watch(page):
    page.on("console", lambda m: m.type == "error" and problems.append(f"console error: {m.text}"))
    page.on("pageerror", lambda e: problems.append(f"page error: {e}"))
    page.on("response", lambda r: r.status >= 400 and problems.append(f"HTTP {r.status}: {r.url}"))


with sync_playwright() as p:
    import glob, os
    shell = sorted(glob.glob(os.path.expanduser("~/Library/Caches/ms-playwright/chromium_headless_shell-*/*/chrome-headless-shell")))
    browser = p.chromium.launch(executable_path=shell[-1] if shell else None)
    for name, (w, h) in SIZES.items():
        # Hero with motion, recorded, then a still once the demo has played.
        ctx = browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=2,
                                  record_video_dir=str(out / f"video-{name}"),
                                  record_video_size={"width": w, "height": h})
        ctx.route("**/*", local_only)
        page = ctx.new_page()
        watch(page)
        page.goto(base + "/", wait_until="load")
        page.wait_for_timeout(9000)
        page.screenshot(path=str(out / f"{name}-hero.png"))
        ctx.close()

        # Full page as reduced-motion stills.
        ctx = browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=1,
                                  reduced_motion="reduce")
        ctx.route("**/*", local_only)
        page = ctx.new_page()
        watch(page)
        page.goto(base + "/", wait_until="load")
        page.wait_for_timeout(1500)
        page.screenshot(path=str(out / f"{name}-full.png"), full_page=True)

        # Waitlist with a synthetic address.
        email = page.locator("input[type=email]").first
        if email.count():
            email.scroll_into_view_if_needed()
            email.fill("ada@example.com")
            email.press("Enter")
            page.wait_for_timeout(1500)
            page.screenshot(path=str(out / f"{name}-waitlist.png"))
        ctx.close()
    browser.close()

for d in [p for p in out.glob("video-*") if p.is_dir()]:
    vids = sorted(d.glob("*.webm"))
    if vids:
        vids[-1].rename(out / f"{d.name}.webm")
    for v in d.glob("*"):
        v.unlink()
    d.rmdir()
(out / "problems.txt").write_text("\n".join(problems) + "\n" if problems else "none\n")
print("saved to", out, "| problems:", len(problems))

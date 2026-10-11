#!/usr/bin/env python3
"""Inspect publishable paths and embedded metadata without printing matched data."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


SECRET = re.compile(
    rb"(?:sk-ant-[A-Za-z0-9_-]{20,}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)"
)


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rules", type=Path, required=True)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--staged", action="store_true", help="Read the Git index rather than working files")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    rules = json.loads(args.rules.read_text())
    patterns = [(rule["name"], re.compile(rule["pattern"], re.I)) for rule in rules]
    command = ["git", "ls-files", "--cached", "-z"]
    if not args.staged:
        command = ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
    names = subprocess.check_output(command, cwd=root).decode().split("\0")
    files = [root / name for name in names if name]
    if args.bundle:
        files.extend(path for path in args.bundle.rglob("*") if path.is_file())
    failures = []
    examined = 0
    for path in sorted(set(files)):
        if not path.is_file():
            continue
        examined += 1
        label = str(path.relative_to(root)) if path.is_relative_to(root) else str(path)
        if args.staged and path.is_relative_to(root) and str(path.relative_to(root)) in names:
            raw = subprocess.check_output(["git", "show", ":" + str(path.relative_to(root))], cwd=root)
        else:
            raw = path.read_bytes()
        text = raw.decode("utf-8", errors="ignore")
        # Binary fonts, icons and images may carry identity in name tables,
        # comments or text chunks even when their rendered pixels look clean.
        for name, pattern in patterns:
            if pattern.search(label) or pattern.search(text):
                failures.append({"path": label, "reason": name})
        if SECRET.search(raw):
            failures.append({"path": label, "reason": "credential pattern"})
        if path.suffix == ".map":
            failures.append({"path": label, "reason": "source map"})
        if path.is_symlink():
            failures.append({"path": label, "reason": "symlink requires inspection"})
    result = {"files_examined": examined, "failures": failures, "passed": not failures}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run())

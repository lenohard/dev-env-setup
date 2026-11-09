#!/usr/bin/env python3
"""Copy the shared Karabiner complex-modification rules into the live config.

Karabiner Elements reads exactly one file (~/.config/karabiner/karabiner.json)
and cannot include others, so we merge instead of symlinking: the rules in
configs/karabiner/rules.json replace each profile's
`complex_modifications.rules`, while machine-local parts (`devices`,
`simple_modifications`, `fn_function_keys`, keyboard type) are left untouched.

Idempotent: exits without touching the file when nothing differs.

Usage: apply.py [--dry-run] [--config PATH]
"""

from __future__ import annotations

import argparse
import copy
import json
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RULES_FILE = HERE / "rules.json"
DEFAULT_CONFIG = Path.home() / ".config" / "karabiner" / "karabiner.json"


def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:  # pragma: no cover - defensive
        sys.exit(f"error: {path} is not valid JSON: {exc}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not RULES_FILE.exists():
        sys.exit(f"error: shared rules not found: {RULES_FILE}")
    if not args.config.exists():
        print(f"skip: no Karabiner config at {args.config}")
        return 0

    shared = load(RULES_FILE)["rules"]
    current = load(args.config)

    changed = []
    for profile in current.get("profiles", []):
        rules = profile.setdefault("complex_modifications", {}).setdefault("rules", [])
        if json.dumps(rules, sort_keys=True) == json.dumps(shared, sort_keys=True):
            continue
        old = {r.get("description") for r in rules}
        new = {r.get("description") for r in shared}
        profile["complex_modifications"]["rules"] = copy.deepcopy(shared)
        changed.append(
            (
                profile.get("name", "<unnamed>"),
                sorted(new - old),
                sorted(old - new),
            )
        )

    if not changed:
        print(f"up to date: {args.config}")
        return 0

    for name, added, removed in changed:
        print(f"profile {name!r}: +{len(added)} -{len(removed)} rules")
        for desc in added:
            print(f"  + {desc}")
        for desc in removed:
            print(f"  - {desc}")

    if args.dry_run:
        print("dry run: nothing written")
        return 0

    backup = args.config.with_name(f"{args.config.name}.bak-shared-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(args.config, backup)
    args.config.write_text(json.dumps(current, indent=4, ensure_ascii=False) + "\n")
    print(f"wrote {args.config} (backup: {backup.name})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
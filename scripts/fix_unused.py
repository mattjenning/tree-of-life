#!/usr/bin/env python3
"""
Mechanical cleanup of selene's unused_variable warnings:
- for i = N, M  -> for _ = N, M     (loop var unused)
- for i, x in   -> for _, x in       (loop var unused, kept second)
- function(name, ...) -> function(_name, ...)   (callback param unused)
- local Foo = game:GetService("Foo")  -> drop entirely (service unused)

Reads selene src/ output for unused_variable warnings, classifies each,
and applies targeted edits. Writes a report; rolls back nothing - the
caller is expected to verify with selene + git diff.

Skips warnings on lines we can't confidently classify (e.g. complex
multi-assignment) so a follow-up manual pass can handle the rest.
"""
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


WARN_RE = re.compile(r"warning\[unused_variable\]: (\w+) is (assigned|defined)")
LOC_RE = re.compile(r"(\S+\.lua):(\d+):(\d+)")


def parse_warnings(text: str):
    out = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = WARN_RE.search(line)
        if not m:
            continue
        name = m.group(1)
        for j in range(i + 1, min(i + 5, len(lines))):
            lm = LOC_RE.search(lines[j])
            if lm:
                out.append((lm.group(1), int(lm.group(2)), int(lm.group(3)), name))
                break
    return out


def fix_loop_var(line: str, name: str) -> str | None:
    # for i = ... -> for _ = ...
    m = re.search(r"\bfor\s+" + re.escape(name) + r"\s*=", line)
    if m:
        return line[:m.start()] + "for _ =" + line[m.end():]
    # for i, x in ... -> for _, x in ...
    m = re.search(r"\bfor\s+" + re.escape(name) + r"\s*,", line)
    if m:
        return line[:m.start()] + "for _," + line[m.end():]
    return None


def fix_callback_param(line: str, name: str) -> str | None:
    # function(name, ...) or function(prefix, name, ...) → rename to _name.
    # Match the parameter inside a function() definition.
    pat = re.compile(r"(function\s*\([^)]*?)\b" + re.escape(name) + r"\b")
    m = pat.search(line)
    if m:
        return line[:m.start()] + m.group(1) + "_" + name + line[m.end():]
    # Same for arrow-function-style locals: local fn = function(name) ...
    pat = re.compile(r"(:\s*Connect\s*\(\s*function\s*\([^)]*?)\b" + re.escape(name) + r"\b")
    m = pat.search(line)
    if m:
        return line[:m.start()] + m.group(1) + "_" + name + line[m.end():]
    return None


def is_service_require(line: str, name: str) -> bool:
    pat = re.compile(
        r"^\s*local\s+" + re.escape(name) + r"\s*=\s*game:GetService\("
    )
    return bool(pat.search(line))


def main():
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    selene_bin = (
        Path.home() / ".aftman" / "tool-storage" / "Kampfkarren" / "selene" / "0.30.1" / "selene.exe"
    )
    if not selene_bin.exists():
        cmd = ["selene", "src"]
    else:
        cmd = [str(selene_bin), "src"]
    proc = subprocess.run(
        cmd, capture_output=True, text=True, errors="replace", cwd=str(repo)
    )
    warnings = parse_warnings(proc.stdout + "\n" + proc.stderr)
    print(f"[fix_unused] {len(warnings)} unused-variable warnings")
    by_file = defaultdict(list)
    for path, ln, col, name in warnings:
        by_file[str(repo / path)].append((ln, col, name))
    fixed_loop = 0
    fixed_cb = 0
    fixed_service = 0
    skipped = 0
    for full, items in by_file.items():
        p = Path(full)
        if not p.exists():
            print(f"[fix_unused] SKIP missing file: {full}")
            continue
        text = p.read_text(encoding="utf-8")
        # Preserve trailing newline + line-ending convention.
        eol = "\r\n" if "\r\n" in text else "\n"
        bare_lines = text.split(eol)
        # Apply rightmost-first per line so column offsets remain valid.
        items.sort(key=lambda x: (x[0], -x[1]))
        for ln, col, name in items:
            if ln - 1 >= len(bare_lines):
                skipped += 1
                continue
            line = bare_lines[ln - 1]
            new = fix_loop_var(line, name)
            if new is not None:
                bare_lines[ln - 1] = new
                fixed_loop += 1
                continue
            if is_service_require(line, name):
                # Drop the entire line.
                bare_lines.pop(ln - 1)
                # Subsequent same-line edits won't apply; we sorted by line.
                fixed_service += 1
                continue
            new = fix_callback_param(line, name)
            if new is not None:
                bare_lines[ln - 1] = new
                fixed_cb += 1
                continue
            skipped += 1
        new_text = eol.join(bare_lines)
        if new_text != text:
            p.write_text(new_text, encoding="utf-8", newline="")
            print(f"  {p.relative_to(repo)}")
    print(
        f"[fix_unused] loop_var={fixed_loop}  callback_param={fixed_cb}  "
        f"service_require={fixed_service}  skipped={skipped}"
    )


if __name__ == "__main__":
    main()

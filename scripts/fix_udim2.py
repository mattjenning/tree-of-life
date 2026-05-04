#!/usr/bin/env python3
"""
Targeted UDim2.new -> UDim2.fromOffset / UDim2.fromScale fixer.

Driven by selene's roblox_manual_fromscale_or_fromoffset warnings:
- UDim2.new(0, X, 0, Y)        -> UDim2.fromOffset(X, Y)
- UDim2.new(S, 0, T, 0)        -> UDim2.fromScale(S, T)

Reads file/line/column AND warning kind from selene output, parses the
UDim2.new(...) call at the reported position with balanced-paren args,
and reconstructs the call. Targeted to specific lines so we never touch
mixed-form calls like UDim2.new(0, x, 1, 0) that selene didn't flag.

Usage:
    python fix_udim2.py [repo_root]

Runs `selene src/` itself, parses the output, applies fixes in-place,
and reports counts.
"""
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


def split_args(s: str) -> list[str]:
    """Split a parenthesized arg list at top-level commas, ignoring nested
    parens / brackets / strings. Input is the contents BETWEEN the outer
    parens (no leading '(' or trailing ')')."""
    args = []
    depth = 0
    cur = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c in "([{":
            depth += 1
            cur.append(c)
        elif c in ")]}":
            depth -= 1
            cur.append(c)
        elif c == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
        elif c in '"\'':
            # Skip string literal, including escapes.
            quote = c
            cur.append(c)
            i += 1
            while i < n:
                cur.append(s[i])
                if s[i] == "\\" and i + 1 < n:
                    cur.append(s[i + 1])
                    i += 2
                    continue
                if s[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        else:
            cur.append(c)
        i += 1
    if cur:
        args.append("".join(cur).strip())
    return args


def find_call_end(line: str, open_paren_idx: int) -> int | None:
    """Given the index of the '(' in 'UDim2.new(', return the index of the
    matching ')'. Returns None if unbalanced on this line."""
    depth = 0
    i = open_paren_idx
    n = len(line)
    while i < n:
        c = line[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        elif c in '"\'':
            quote = c
            i += 1
            while i < n:
                if line[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                if line[i] == quote:
                    break
                i += 1
        i += 1
    return None


# Match warning header line + the source pointer line that follows.
WARN_RE = re.compile(
    r"warning\[roblox_manual_fromscale_or_fromoffset\]: this UDim2\.new call only sets (offset|scale)"
)
# Match path:line:col for any .lua file. selene's box-drawing prefix (┌─)
# is unreliable across stdin/stdout encodings, so we look for the
# canonical "src/.../foo.lua:N:M" triple instead.
LOC_RE = re.compile(r"(\S+\.lua):(\d+):(\d+)")


def parse_selene_output(text: str) -> list[tuple[str, int, int, str]]:
    """Yields (path, line, col, kind) tuples for each UDim2 warning."""
    out = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = WARN_RE.search(line)
        if not m:
            continue
        kind = m.group(1)  # 'offset' or 'scale'
        # The location line follows; find the next ┌─ line.
        for j in range(i + 1, min(i + 5, len(lines))):
            lm = LOC_RE.search(lines[j])
            if lm:
                path = lm.group(1).replace("\\", "/")
                ln = int(lm.group(2))
                col = int(lm.group(3))
                out.append((path, ln, col, kind))
                break
    return out


def fix_one(file_lines: list[str], line_idx: int, col_idx: int, kind: str) -> bool:
    """Apply one fix in-place on file_lines. line_idx + col_idx are
    1-indexed (selene). Returns True if a substitution was made."""
    line = file_lines[line_idx - 1]
    # Find the 'UDim2.new(' starting at or just before col_idx.
    # Selene's column is the start of 'UDim2'.
    start = col_idx - 1
    needle = "UDim2.new("
    if not line[start:start + len(needle)] == needle:
        # Maybe selene's column is off by a bit; search a small window.
        idx = line.find(needle, max(0, start - 4), start + 4)
        if idx == -1:
            return False
        start = idx
    open_paren = start + len(needle) - 1  # the '(' position
    close_paren = find_call_end(line, open_paren)
    if close_paren is None:
        return False
    args_str = line[open_paren + 1:close_paren]
    args = split_args(args_str)
    if len(args) != 4:
        return False
    if kind == "offset":
        # Args: 0, X, 0, Y -> fromOffset(X, Y)
        if args[0] != "0" or args[2] != "0":
            return False
        new_call = f"UDim2.fromOffset({args[1]}, {args[3]})"
    elif kind == "scale":
        # Args: S, 0, T, 0 -> fromScale(S, T)
        if args[1] != "0" or args[3] != "0":
            return False
        new_call = f"UDim2.fromScale({args[0]}, {args[2]})"
    else:
        return False
    file_lines[line_idx - 1] = line[:start] + new_call + line[close_paren + 1:]
    return True


def main():
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    print(f"[fix_udim2] repo: {repo}")
    selene_bin = (
        Path.home() / ".aftman" / "tool-storage" / "Kampfkarren" / "selene" / "0.30.1" / "selene.exe"
    )
    if not selene_bin.exists():
        # Fallback: just call 'selene' on PATH.
        cmd = ["selene", "src"]
    else:
        cmd = [str(selene_bin), "src"]
    # IMPORTANT: pass "src" relative + cwd=repo so selene's output uses
    # relative paths. Absolute paths break naive \S+\.lua regex when the
    # repo path contains a space ("Tree of Life").
    proc = subprocess.run(
        cmd, capture_output=True, text=True, errors="replace", cwd=str(repo)
    )
    warnings = parse_selene_output(proc.stdout + "\n" + proc.stderr)
    print(f"[fix_udim2] {len(warnings)} UDim2 warnings to fix")
    by_file: defaultdict[str, list] = defaultdict(list)
    for path, ln, col, kind in warnings:
        # selene paths are repo-relative.
        full = repo / path
        by_file[str(full)].append((ln, col, kind))
    fixed_total = 0
    skipped_total = 0
    for full_path, items in by_file.items():
        p = Path(full_path)
        if not p.exists():
            print(f"[fix_udim2] SKIP missing file: {full_path}")
            continue
        lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
        # Strip line endings for processing, then re-add.
        eol_per_line = []
        bare = []
        for ln in lines:
            if ln.endswith("\r\n"):
                eol_per_line.append("\r\n")
                bare.append(ln[:-2])
            elif ln.endswith("\n"):
                eol_per_line.append("\n")
                bare.append(ln[:-1])
            else:
                eol_per_line.append("")
                bare.append(ln)
        # Process line-by-line. A single line may have multiple warnings;
        # apply rightmost-first so column offsets remain valid.
        items.sort(key=lambda x: (x[0], -x[1]))
        file_fixed = 0
        file_skipped = 0
        for ln, col, kind in items:
            if fix_one(bare, ln, col, kind):
                file_fixed += 1
            else:
                file_skipped += 1
        if file_fixed:
            new_text = "".join(b + e for b, e in zip(bare, eol_per_line))
            p.write_text(new_text, encoding="utf-8", newline="")
            print(f"  {p.relative_to(repo)}  fixed={file_fixed}  skipped={file_skipped}")
        fixed_total += file_fixed
        skipped_total += file_skipped
    print(f"[fix_udim2] total fixed={fixed_total}  skipped={skipped_total}")


if __name__ == "__main__":
    main()

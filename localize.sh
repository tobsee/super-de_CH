#!/bin/bash
# localize.sh — build a German-localized SUPER from pristine upstream + de.map.
#
# Usage:  ./localize.sh [vendor/super] [de.map]   ->   build/super-de
#
# Replacement is LITERAL: for each `display_string_*="..."` assignment line in the vendor script,
# the exact quoted value is looked up in de.map (string equality, never regex) and swapped for its
# German. Nothing else in the file is touched. The version string and all code are preserved.
#
# Reports three categories and EXITS NON-ZERO if STALE or UNTRANSLATED is non-empty:
#   A. Applied      — map entries found in vendor and replaced.
#   B. Stale        — map entries whose English no longer exists in vendor (changed/removed upstream).
#   C. Untranslated — vendor strings with no usable German (no map entry, or German == English / TODO).
#
# Output is written atomically: a temp file is fully built and only moved into place on success.

set -euo pipefail

cd "$(dirname "$0")"

VENDOR="${1:-vendor/super}"
MAP="${2:-de.map}"
PATCH="${3:-de.patch}"
OUT="build/super-de"

[[ -f "${VENDOR}" ]] || { echo "ERROR: vendor script not found: ${VENDOR}" >&2; exit 2; }
[[ -f "${MAP}"    ]] || { echo "ERROR: map not found: ${MAP}" >&2; exit 2; }
# PATCH is optional: absent file = no out-of-function patches to apply.

mkdir -p "$(dirname "${OUT}")"

VENDOR="${VENDOR}" MAP="${MAP}" PATCH="${PATCH}" OUT="${OUT}" python3 - <<'PY'
import os, sys, collections

vendor = os.environ["VENDOR"]
mappath = os.environ["MAP"]
patchpath = os.environ["PATCH"]
out = os.environ["OUT"]

# --- load de.map: english_raw -> german_raw -------------------------------------------------
# A "# TODO" comment line marks the FOLLOWING entry as not-yet-translated (English placeholder),
# so localize reports it as untranslated even though English==English. A bare English==English
# entry (no preceding TODO) means "intentionally identical in German" and is treated as resolved.
mapping = collections.OrderedDict()
todo_keys = set()
pending_todo = False
with open(mappath, encoding="utf-8") as f:
    for n, line in enumerate(f, 1):
        line = line.rstrip("\n")
        if not line:
            continue
        if line.lstrip().startswith("#"):
            if line.lstrip().startswith("# TODO translate"):
                pending_todo = True
            continue
        eng, sep, ger = line.partition("\t")
        if not sep:
            print(f"ERROR: {mappath}:{n}: missing TAB separator", file=sys.stderr)
            sys.exit(2)
        if eng in mapping and mapping[eng] != ger:
            print(f"ERROR: {mappath}:{n}: duplicate English key with conflicting German:\n  {eng!r}", file=sys.stderr)
            sys.exit(2)
        mapping[eng] = ger
        if pending_todo:
            todo_keys.add(eng)
        pending_todo = False

# --- load de.patch: out-of-function line replacements ---------------------------------------
# These reach lines that de.map cannot (date/time format constants and forced LC_TIME on the
# user-facing `date` calls), which live OUTSIDE set_display_strings_language(). Matching is on the
# leading-whitespace-stripped line by exact equality; original indentation is preserved. Each `old`
# must match at least one line (some date-assembly lines recur verbatim at several call sites — all
# occurrences are patched); ZERO matches is reported and fails the build (D. below), so an upstream
# edit that moves/renames a target line is caught rather than silently dropped.
patches = []   # list of (lineno_in_patch, old_stripped, new_stripped)
if os.path.exists(patchpath):
    with open(patchpath, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            old, sep, new = line.partition("\t")
            if not sep:
                print(f"ERROR: {patchpath}:{n}: missing TAB separator", file=sys.stderr)
                sys.exit(2)
            patches.append((n, old, new))

# --- scan vendor for translatable assignments (mirrors extract-strings.sh scoping) ----------
def is_computed(val):
    return val.startswith("$(") or val.startswith('"$(') or (
        val.startswith('"${') and val.endswith('}"') and '"' not in val[1:-1])

vendor_strings = collections.OrderedDict()   # english_raw -> count of occurrences in function
inside = False
import re
assign_re = re.compile(r'^([ \t]*)(display_string_[a-z_0-9]*)=("(.*)")[ \t]*$')

lines = []
with open(vendor, encoding="utf-8") as f:
    for line in f:
        lines.append(line)

new_lines = []
applied = collections.OrderedDict()   # english -> german (that were actually replaced)
for line in lines:
    stripped_nl = line.rstrip("\n")
    if re.match(r'^set_display_strings_language\(\)', stripped_nl):
        inside = True
    elif inside and re.match(r'^}', stripped_nl):
        inside = False

    if inside:
        m = assign_re.match(stripped_nl)
        if m:
            indent, name, quoted, inner = m.group(1), m.group(2), m.group(3), m.group(4)
            value_with_quotes = quoted          # e.g. "Restart Now"
            raw = inner                          # e.g. Restart Now  (verbatim inner text)
            if not is_computed(value_with_quotes):
                vendor_strings[raw] = vendor_strings.get(raw, 0) + 1
                ger = mapping.get(raw)
                # A usable translation must exist AND differ from the English (German==English means
                # untranslated/TODO placeholder — leave the English in place, report as untranslated).
                if ger is not None and ger != raw:
                    newline = f'{indent}{name}="{ger}"\n' if line.endswith("\n") else f'{indent}{name}="{ger}"'
                    new_lines.append(newline)
                    applied[raw] = ger
                    continue
    new_lines.append(line)

# --- apply de.patch: out-of-function line replacements --------------------------------------
import re as _re
_indent_re = _re.compile(r'^([ \t]*)(.*)$')
patched = []        # (old_stripped, new_stripped) actually applied
patch_misses = []   # (lineno, old_stripped) that matched no line
for pn, old, new in patches:
    hit_indices = []
    for i, ln in enumerate(new_lines):
        body = ln.rstrip("\n")
        m = _indent_re.match(body)
        if m and m.group(2) == old:
            hit_indices.append(i)
    if not hit_indices:
        patch_misses.append((pn, old))
        continue
    for i in hit_indices:
        ln = new_lines[i]
        indent = _indent_re.match(ln.rstrip("\n")).group(1)
        new_lines[i] = f'{indent}{new}\n' if ln.endswith("\n") else f'{indent}{new}'
    patched.append((old, new))

# --- categories -----------------------------------------------------------------------------
# B. Stale: map English keys that do not appear among vendor's translatable strings.
stale = [e for e in mapping if e not in vendor_strings]
# C. Untranslated: vendor strings that need attention. A string is considered resolved when it has
#    a map entry — including an explicit English==English entry, which means "intentionally kept in
#    German-as-English" (e.g. "OK", or sentinel values that double as control-flow keys). Only strings
#    with NO map entry at all, or marked TODO, are reported as untranslated.
untranslated = [s for s in vendor_strings
                if (s not in mapping) or (s in todo_keys)]

# --- report ---------------------------------------------------------------------------------
def show(s):
    return s if len(s) <= 100 else s[:97] + "..."

print(f"A. Applied      : {len(applied)} string(s) replaced.")
print(f"B. Stale        : {len(stale)} map entr{'y' if len(stale)==1 else 'ies'} no longer in vendor.")
for s in stale:
    print(f"     STALE: \"{show(s)}\"")
print(f"C. Untranslated : {len(untranslated)} vendor string(s) needing German.")
for s in untranslated:
    print(f"     TODO : \"{show(s)}\"")
print(f"D. Patched      : {len(patched)} out-of-function line(s) replaced; {len(patch_misses)} miss(es).")
for pn, s in patch_misses:
    print(f"     MISS ({patchpath}:{pn}): \"{show(s)}\"")

# --- write output atomically ----------------------------------------------------------------
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as g:
    g.writelines(new_lines)
os.chmod(tmp, 0o755)
os.replace(tmp, out)
print(f"\nWrote {out}")

if stale or untranslated or patch_misses:
    print("\nResult: NOT CLEAN — resolve STALE/UNTRANSLATED in de.map and/or MISS (re-anchor) in de.patch.",
          file=sys.stderr)
    sys.exit(1)
print("\nResult: CLEAN — all vendor strings translated, all patches applied, no stale entries.")
PY

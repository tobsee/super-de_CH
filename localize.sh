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
OUT="build/super-de"

[[ -f "${VENDOR}" ]] || { echo "ERROR: vendor script not found: ${VENDOR}" >&2; exit 2; }
[[ -f "${MAP}"    ]] || { echo "ERROR: map not found: ${MAP}" >&2; exit 2; }

mkdir -p "$(dirname "${OUT}")"

VENDOR="${VENDOR}" MAP="${MAP}" OUT="${OUT}" python3 - <<'PY'
import os, sys, collections

vendor = os.environ["VENDOR"]
mappath = os.environ["MAP"]
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

# --- write output atomically ----------------------------------------------------------------
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as g:
    g.writelines(new_lines)
os.chmod(tmp, 0o755)
os.replace(tmp, out)
print(f"\nWrote {out}")

if stale or untranslated:
    print("\nResult: NOT CLEAN — resolve STALE (re-map English) and/or UNTRANSLATED (add German) in de.map.",
          file=sys.stderr)
    sys.exit(1)
print("\nResult: CLEAN — all vendor strings translated, no stale map entries.")
PY

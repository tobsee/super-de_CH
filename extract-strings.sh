#!/bin/bash
# extract-strings.sh — emit the user-facing (translatable) strings from a SUPER script.
#
# Usage:  ./extract-strings.sh <path-to-super-script>
#
# Output: one record per translatable assignment, as:
#             display_string_name<TAB>"the quoted literal value"
#         The value includes its surrounding double quotes verbatim.
#
# Rationale (see README / plan): SUPER defines 100% of its user-facing text inside the single
# function set_display_strings_language() as single-line, double-quoted literals of the form:
#     display_string_foo="Some text ${with_vars} and \"escapes\" and \n line breaks"
# We scope extraction to that function body so that computed display_string_* assignments
# elsewhere in the script (e.g. =$(date ...), ="${other}", arithmetic) are never picked up.
#
# We are deliberately conservative: over-extraction is harmless (unmapped entries pass through
# unchanged in localize.sh) whereas missing a prompt is the real failure.

set -euo pipefail

SCRIPT="${1:-}"
if [[ -z "${SCRIPT}" || ! -f "${SCRIPT}" ]]; then
	echo "Usage: $0 <path-to-super-script>" >&2
	exit 2
fi

awk '
	# Locate the function and its closing brace (a "}" at column 0).
	/^set_display_strings_language\(\)/ { inside = 1; next }
	inside && /^}/                      { inside = 0 }
	!inside { next }

	# Match an assignment to a display_string_* variable whose value starts with a double quote.
	/^[[:space:]]*display_string_[a-z_0-9]*="/ {
		line = $0
		sub(/^[[:space:]]*/, "", line)          # strip leading indentation (tabs/spaces)
		eq   = index(line, "=")
		name = substr(line, 1, eq - 1)
		val  = substr(line, eq + 1)             # everything after the first "=" (keeps quotes)

		# Defensive: skip values that are actually command substitutions or pure variable
		# expansions with no literal text (computed, not translatable). The current function
		# has none of these, but a future upstream release might.
		if (val ~ /^\$\(/)    next               # =$(...)
		if (val ~ /^"\$\(/)   next               # ="$(...)"
		if (val ~ /^"\$\{[^"]*\}"$/) next         # ="${only_a_var}"  (no literal text)

		print name "\t" val
	}
' "${SCRIPT}"

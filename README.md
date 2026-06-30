# super-de_CH — German (Swiss High German) localization of SUPER

This repository maintains a **German-localized build** of
[**S.U.P.E.R.M.A.N. (`super`)**](https://github.com/Macjutsu/super) by Kevin M. White — the
open-source macOS software-update enforcement tool for Mac admins.

> This is an unofficial localization fork. For the tool itself, its documentation, options,
> screenshots, and support, see the **upstream project: https://github.com/Macjutsu/super**
> (and its [Wiki](https://github.com/Macjutsu/super/wiki)). All credit for `super` goes there.

## What this repo does

`super` keeps **all of its user-facing text in one place** — the `set_display_strings_language()`
function — as simple `display_string_*="..."` assignments. This repo translates that text into
**Swiss High German** (Schweizer Hochdeutsch: always `ss`, never `ß`) **without ever hand-editing
the upstream script**.

Instead:

- Pristine upstream `super` lives untouched in [`vendor/super`](vendor/super).
- All German strings live in one map file, [`de.map`](de.map) (`English<TAB>German` pairs).
- A small companion file, [`de.patch`](de.patch), fixes German-relevant text **outside** that one
  function — the date/time display formats and forcing a German locale on date output (so dialogs show
  e.g. `Di. 30. Juni 19:50 Uhr` instead of `Tue Jun 30 7:50 PM`).
- [`localize.sh`](localize.sh) regenerates the localized script into `build/super-de`, and reports
  exactly which strings are **new** (need translating) or **changed upstream** (need re-mapping/re-anchoring).

This keeps the fork trivially re-syncable with each new `super` release: drop in the new upstream
file, re-run the build, translate only what changed.

**Currently localized `super` version: 5.1.0.**

## Usage

```sh
git show vX.Y.Z:super > vendor/super        # X.Y.Z = the upstream release you want
./localize.sh vendor/super de.map de.patch  # -> build/super-de
```

Deploy `build/super-de` instead of the upstream `super`. The localized build differs from upstream
**only** in the translated `display_string_*` lines plus the `de.patch` targets (the two date/time
format constants and the `LC_TIME` prefixes on date calls) — the version string, all other logic, and
everything else are byte-for-byte identical.

See **[LOCALIZATION.md](LOCALIZATION.md)** for the full format reference and the per-release update
procedure.

## License

`super` is distributed under the Apache License 2.0 (see [`LICENSE`](LICENSE)); this localization fork
follows the same terms. `super` is the work of Kevin M. White and the SUPERMAN project.

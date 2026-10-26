# Version-bump conventions reference

Read this before assessing a bump or running `apply`. It is the contract
`scripts/version_bump.sh` is tested against (`scripts/test_version_bump.sh`
fails if the type list or scheme names here drift from the script). Kept
separate from SKILL.md so ecosystem detail can grow without bloating what
loads on every invocation.

## Contents
1. [Type → scheme](#how-a-version-is-decided-type--scheme)
2. [Project-type detection](#project-type-detection)
3. [Schemes (format + bump rules)](#schemes-format--bump-rules)
4. [Ecosystem notes](#ecosystem-notes) — Node · Rust · Python · R · Ruby
   · Go · Maven · PHP/Composer · plain VERSION file
5. [Out-of-sync secondary locations](#out-of-sync-secondary-locations)
6. [What `apply` writes (and does not)](#what-apply-writes-and-does-not)
7. [API-diff fidelity](#api-diff-fidelity-by-ecosystem)
8. [Changelog rules](#changelog-rules)
9. [Gotchas](#gotchas)

## How a version is decided: type → scheme

The detected **project type** selects a **scheme**. The scheme owns both the
version *format* (which strings are valid) and the *bump arithmetic*
(`patch`, `minor`, … → exact new string). The script computes the candidates
(`scan` prints `kind -> new version`); do not recompute them by hand and do
not apply generic SemVer judgment to a non-SemVer ecosystem.

Rules that hold for every scheme:
- A scheme accepts **only** its documented canonical grammar. Anything else
  (build metadata, non-normalized spelling, CalVer, `${revision}`, workspace
  inheritance, dynamic versions) makes `scan`/`apply` exit **3** with the
  reason. Report it and stop; never guess a format.
- From a pre-release/dev version, `patch|minor|major` are refused (exit-2
  style "n/a"): the user must choose the ecosystem's finishing or
  continuing kind (`release`, `prerelease`/`pre`, `dev`, `snapshot`) or give
  an explicit version, which `apply` validates against the same grammar.
- **`major` and `release` are user-only.** Never propose them; always ask
  (even where SemVer §4 would let a `0.y.z` package skip a major).
  Starting a *new* pre-release series (`prepatch`, `a1`, `rc1` from a final
  version) is not a kind: the user supplies the explicit version.
- Exit codes: `0` ok · `1` usage/environment · `2` refused (mismatch, `<old>`
  is not the current version, nothing changed, post-check failed) · `3`
  unsupported/unparseable version.

## Project-type detection

First match wins, in this order. Override with `--type=` and/or
`--manifest=` (both `scan` and `apply`). `scan` lists any other manifests it
found so a wrong pick (e.g. `package.json` used only for tooling next to a
`go.mod`) is visible.

<!-- types:start -->
- `r` — detected by `DESCRIPTION`; read from the `Version:` line.
- `rust` — `Cargo.toml`; `version =` under `[package]`.
- `node` — `package.json`; top-level `"version"` (brace depth 1).
- `python` — `pyproject.toml` with `[project]` or `[tool.poetry]`;
  `version =` in that table.
- `python-setuptools` — `setup.cfg` / `setup.py` (also when
  `pyproject.toml` has only `[build-system]`); `[metadata] version =` or a
  `version="..."` literal.
- `ruby` — `*.gemspec`; the quoted `.version =` in the gemspec, else
  `VERSION = "…"` in `lib/<gem>/version.rb` (dashes in the gem name become
  `/`).
- `php` — `composer.json`; `"version"` if present, else the latest
  reachable git tag.
- `go` — `go.mod` (root only); the latest reachable `v*` git tag.
- `maven` — `pom.xml`; the project's own `<version>` (direct child of the
  root element).
- `generic` — `VERSION`; first line.
<!-- types:end -->

## Schemes (format + bump rules)

<!-- schemes:start -->
Each entry: scheme, used by, accepted grammar, kinds the script computes.

- `semver` — node, rust, generic. `X.Y.Z[-pre.id…]` (SemVer 2.0);
  `+build` → exit 3. Kinds: `patch` `minor` `major*` `prerelease`
  `release*`.
- `pep440` — python. `[N!]X.Y.Z[aN|bN|rcN][.postN][.devN]`, lowercase,
  normalized, no `+local`. Kinds: `patch` `minor` `major*` `pre` `dev`
  `release*`.
- `rver` — r. `X.Y.Z` or `X.Y.Z.<dev>` (dot form; `.9000` = development).
  Kinds: `patch` `minor` `major*` `dev`.
- `rubygems` — ruby. `X.Y.Z` or `X.Y.Z.<letters>[N]` /
  `X.Y.Z.<letters>.N`. Kinds: `patch` `minor` `major*` `prerelease`
  `release*`.
- `gomod` — go. `vX.Y.Z[-pre]` (leading `v`); no `+incompatible`, no
  pseudo-versions. Kinds: `patch` `minor` `major*` `prerelease` `release*`.
- `maven` — maven. `X.Y.Z[-SNAPSHOT]`. Kinds: `patch` `minor` `major*`
  `snapshot` `release*`.
- `composer` — php. SemVer with optional leading `v`. Kinds: `patch`
  `minor` `major*` `prerelease` `release*`.
<!-- schemes:end -->

`*` = user-only (see rules above). A kind that does not apply to the current
version prints `n/a (reason)` instead of a guess.

## Ecosystem notes

Each note says what the scheme enforces and why, with the source it was
checked against.

### Node / npm (`semver`)
- Strict SemVer 2.0 (semver.org): pre-release `-id.N`, build metadata `+x`
  ignored for precedence — the script refuses build metadata rather than
  carry it through a bump.
- `prerelease` increments the trailing numeric identifier of `rc.1`-style
  pre-releases (node-semver `inc` semantics). A bare `-rc` or `-beta` (no
  number) cannot be incremented → give an explicit version.
- `package.json` is authoritative. `package-lock.json` / `npm-shrinkwrap.json`
  carry a second copy of the root version; `scan` checks it and `apply` never
  edits it (run `npm install` to regenerate). `npm version` also commits and
  tags; this skill never does.
- Needs `"version"` on its own line at the top level. Minified one-line JSON
  is reported as unsupported.
- Caret ranges treat `0.y.z` minors as breaking (`^0.2.3` = `>=0.2.3 <0.3.0`);
  this is stated in npm's semver range docs but was not re-fetched when this
  file was written — verify before relying on it. The script prints the
  0.x note only for Rust.

### Rust / Cargo (`semver`)
- SemVer with Cargo's 0.x convention
  (doc.rust-lang.org/cargo/reference/semver.html): for `0.y.z`, a change
  in `y` may be treated as breaking and `z` as compatible; `0.0.z`
  releases are always breaking. So below 1.0 a **breaking change is a
  `minor` bump and additive/fix changes are `patch`**. `scan` prints this
  note for `0.x` crates.
- `version.workspace = true` (inherited) → exit 3; re-run with
  `--manifest=<workspace root>/Cargo.toml`.
- `Cargo.lock` is checked for the crate's own entry and never edited
  (`cargo generate-lockfile` / any build resyncs it).

### Python (`pep440`)
PEP 440 is **not SemVer**
(packaging.python.org/specifications/version-specifiers):
- Grammar: `[N!]N(.N)*[{a|b|rc}N][.postN][.devN]`. Pre-releases have no
  separator (`1.2.0rc1`, never `1.2.0-rc.1`); `.devN` sorts *before* the
  release it precedes; `.postN` sorts after it.
- `1.2` and `1.2.0` are the same version; this skill requires three
  segments (else exit 3) so patch/minor arithmetic is unambiguous.
- Non-normalized spellings (`1.2.0-rc1`, `1.2.0RC1`, `1.2.0.alpha.1`) are
  valid input to pip but are rejected here with the normalized spelling
  shown; normalize first. A SemVer-shaped explicit version such as
  `1.2.0-rc.2` is rejected by `apply` for the same reason.
- Local versions (`1.2.0+local`) must not be published to an index → exit 3.
- Kinds: `pre` (`rc1`→`rc2`, same letter), `dev` (`.dev1`→`.dev2`),
  `release` (strip pre/dev; refused from `.post`), `patch|minor|major` only
  from a final or `.post` release. An epoch (`1!`) is preserved.
- Version locations: `[project]`/`[tool.poetry]` in `pyproject.toml`; or
  `[metadata] version` in `setup.cfg`; or a `version=` literal in `setup.py`.
  A `pyproject.toml` with only `[build-system]` falls through to setuptools.
  Dynamic versions (`dynamic = ["version"]`, hatch/setuptools-scm/`attr:`)
  → exit 3: point `--manifest=` at the file that holds the literal, or tag.
- `__version__ = "…"` literals in `__init__.py`, `__about__.py`, `*version.py`
  (outside tests/docs/examples/build) are secondary locations and are edited
  with the manifest. Generated `_version.py` files are not matched.

### R (`rver`) — r-pkgs.org / usethis / R-exts
- R-exts: `Version` is at least two (usually three) integers separated by `.`
  or `-`. This skill supports only the dotted three-part release form and
  the four-part development form; `1.2-3` and `1.2` → exit 3.
- Release versions are `X.Y.Z`; an in-development package has a fourth
  component that starts at `9000` (`0.0.0.9000` for a new package).
  `0.1.0.9000` means "development after 0.1.0", i.e. 0.1.0 is already out.
- Arithmetic mirrors `desc::desc_bump_version()` as used by
  `usethis::use_version()` (checked against the desc source):

  | Current | patch | minor | major | dev |
  |---|---|---|---|---|
  | `1.2.3` | `1.2.4` | `1.3.0` | `2.0.0` | `1.2.3.9000` |
  | `1.2.3.9000` | `1.2.4` | `1.3.0` | `2.0.0` | `1.2.3.9001` |
  | `0.0.0.9000` | `0.0.1` | `0.1.0` | `1.0.0` | `0.0.0.9001` |

  `patch|minor|major` always produce a **release** version (they drop the
  development component); `dev` appends `.9000` or increments it. There is
  no "drop `.9000`" kind: usethis has none, and re-releasing the same
  `X.Y.Z` is not an R workflow. (An earlier revision of this skill had one;
  removed after checking usethis.)
- The development counter is bumped only when another package needs to
  detect a change, not per commit (r-pkgs.org).
- Single source of truth: `DESCRIPTION`. Other occurrences (`inst/CITATION`,
  `codemeta.json`, pkgdown, README) are listed by `scan` and edited only via
  `--also`. `Imports: dplyr (>= 1.2.0)` is a different package's pin and is
  never touched by `apply`.
- Lifecycle badges (`usethis::use_lifecycle_badge()`) are orthogonal to the
  version; do not add one unless asked.

### Ruby / RubyGems (`rubygems`)
- `Gem::Version`: dot-separated digits and ASCII letters; **any letter
  makes it a pre-release** (`1.2.3.rc1`, `1.2.3.pre`, `1.2.3.beta.1`).
  RubyGems rewrites `-` to `.pre.` (`1.2.3-rc1` ⇒ `1.2.3.pre.rc1`), so the
  SemVer hyphen form means something different → exit 3 with that note.
- `bundle gem` generates `lib/<gem>/version.rb` with `VERSION = "x.y.z"` and
  a gemspec containing `spec.version = Foo::VERSION`. **`version.rb` is
  authoritative when the gemspec only references the constant**; the gemspec
  is used only if it holds a quoted literal (then `version.rb`, if it also
  has a literal, is the checked secondary). A gem named `my-gem` lives at
  `lib/my/gem/version.rb`; `lib/my-gem/version.rb` is tried second.
- `prerelease` increments `rc1`→`rc2` or `beta.1`→`beta.2`; a bare `pre`
  has no number → explicit version.

### Go (`gomod`) — go.dev/ref/mod
- A module's version **is its git tag** (`vMAJOR.MINOR.PATCH[-pre]`, leading
  `v` required); `go.mod` never stores it. `scan` reads the latest reachable
  `v*` tag. This skill **never creates the tag**; after `apply`, the user
  tags the release.
- **Major ≥ 2 changes the module path**: the `module` line must end in
  `/vN` and every import of the module follows. `v0`/`v1` carry no suffix
  (`gopkg.in/…` paths use a dot suffix and are left alone). `apply
  <vOld> <vNew>` therefore rewrites the `module` line and quoted import
  paths beginning with the module path in tracked `.go` files (excluding
  `vendor/`); `--dry-run` lists them first. Non-Go files (README snippets,
  `go.work`) are listed by `scan` but not edited unless `--also`.
- `scan` flags a module path whose `/vN` suffix disagrees with the latest
  tag's major as a MISMATCH.
- Unsupported (exit 3): `+incompatible`, pseudo-versions
  (`v0.0.0-<ts>-<hash>`), non-root `go.mod` (multi-module repos tag with a
  `subdir/` prefix), "major subdirectory" layouts.
- Pre-1.0 (`v0`) and pre-release versions carry no compatibility promise.

### Java / Maven (`maven`)
- Convention: `X.Y.Z`, with `-SNAPSHOT` for builds between releases, normally
  the *next anticipated release* plus `-SNAPSHOT` (maven.apache.org naming
  guide). `release` drops `-SNAPSHOT`; `snapshot` (from a release) gives
  `X.Y.(Z+1)-SNAPSHOT`.
- Only the **project's own** `<version>` (direct child of the root element)
  is read and written; `<parent><version>`, dependency, plugin and
  `dependencyManagement` versions are never touched.
- Exit 3 for: `<modules>` (children inherit/reference the version — use
  `mvn versions:set -DnewVersion=<new>`), property versions (`${revision}`),
  other qualifiers (`-rc1`, `-M1`). Needs one tag per line (as Maven writes it).
- Gradle is not supported (re-run with `--type=generic` only if a plain
  `VERSION` file drives it).

### PHP / Composer (`composer`)
- Composer's schema says `version` should normally be **omitted**: the
  version is inferred from the VCS tag, and setting it by hand "will most
  likely end up creating problems". So for a `composer.json` without
  `"version"`, `apply` writes **nothing** and says so; the user tags
  `vX.Y.Z`. If a `"version"` field exists it is edited like any JSON field.
- Format: `X.Y.Z` or `vX.Y.Z` with optional `-dev`, `-patch`, `-alpha`,
  `-beta`, `-RC` suffixes (+ number). Only plain SemVer shapes are bumped;
  suffix forms that are not `id.N` have no `prerelease` kind.

### Plain `VERSION` file (`semver`)
First line must be canonical SemVer; anything else (CalVer such as
`2024.10`, two-part versions) → exit 3. Use `--type=` + `--manifest=` to
point at a differently named file.

## Out-of-sync secondary locations

A second copy of the version tends to drift. `scan` compares it with the
primary and reports `MISMATCH`/`UNPARSEABLE`; **`scan` exits 2** and
`apply` refuses (exit 2) unless `--force`. An unparseable secondary counts as
a mismatch (it does not fail open).

Secondary location checked per type, and whether `apply` edits it:
- `ruby` — the other of gemspec literal / `version.rb`. Edited.
- `python` — `__version__ = "…"` literals (see Python note). Edited.
- `node` — root `"version"` in `package-lock.json` and
  `npm-shrinkwrap.json`. Not edited (regenerate).
- `rust` — the crate's own entry in `Cargo.lock`. Not edited (regenerate).
- `go` — `go.mod` module-path `/vN` suffix vs the tag's major. Edited
  (rewrite).
- `r`, `php`, `maven`, `generic` — none.

**If scan reports a mismatch, stop.** Show the user both values and which
file is authoritative (the primary), and ask them to fix the secondary or to
confirm `--force`. With `--force` the stale secondary stays stale; say so.
After a normal bump, lockfiles still hold the old version until the package
manager regenerates them — `verify` reports that as a NOTE, not a failure.

## What `apply` writes (and does not)

`apply <old> <new>` validates first, then writes. It refuses (exit 2) if
`<old>` is not the manifest's current version, and (exit 3) if either
version is outside the scheme's grammar.

1. **Always:** the declared version field in the primary file, and editable
   secondary locations (table above). The edit is anchored to the same parse
   the reader uses (e.g. only `[package]` in `Cargo.toml`, only the root
   `<version>` in a POM, only depth-1 `"version"` in JSON), so dependency
   pins in the same file are never rewritten.
2. **Only if named:** `--also=<path>` rewrites whole-token matches of
   `<old>` in that tracked text file. A token match is not adjacent to
   `[0-9A-Za-z_.+-]` (a leading `v` is allowed), so `1.2.0` does not match
   inside `11.2.0`, `1.2.03`, `1.2.0.9000` or `1.2.0-rc1`. Changelogs,
   lockfiles, build output, symlinks, binaries and untracked files are
   refused. `scan` shows every candidate as `file:line:text`; review each —
   other packages' pins, dates and test fixtures appear there too.
3. **Never:** lockfiles, changelogs' past headers, `.git`, vendor/build dirs
   (`node_modules/`, `dist/`, `build/`, `target/`, `vendor/`, `__pycache__/`,
   `*.egg-info/`, `.venv/`, `venv/`, `.tox/`), build artifacts (`*.tar.gz`,
   `*.whl`, `*.gem`), `go.sum`, and for R `man/`. These exclusions match at
   **any depth** (`:(exclude,glob)**/NEWS.md`), so `docs/CHANGELOG.md` and
   `packages/a/package-lock.json` are protected too.
4. `--dry-run` prints exactly what would change and writes nothing.
   After writing, `apply` re-reads the manifest and exits 2 if it does not
   say `<new>`. `verify <old> <new>` re-checks the manifest and secondaries
   and lists remaining whole-token occurrences of `<old>`.

No `git commit`, no `git tag`, no push — ever. A dirty working tree gets a
warning so the bump diff stays reviewable.

## API-diff fidelity by ecosystem

`scan`'s public-API diff is the strongest patch-vs-minor signal, but varies:
- **R**: exact — diffs the generated `NAMESPACE` export list.
- **Rust**: heuristic — top-level `pub fn/struct/enum/trait/const/mod/type`
  in `src/lib.rs` only (misses `pub use`, nested modules, workspaces).
- **Node**: heuristic — top-level `export` in `src/index.ts|js` or
  `index.ts|js` only (misses barrel re-exports).
- **Python**: heuristic — `__all__` in the first `__init__.py` that has one.
- **Ruby / PHP / Go / Maven / generic**: no automated diff; read the commit
  log yourself.

Trust the commit log over the heuristic. The "commits since last bump" range
starts at the last commit that changed the version line (or, for tag-derived
types, at the latest version tag).

## Changelog rules

Keep a Changelog 1.1.0 by default; if a changelog already exists, **match
its existing style** (R's `NEWS.md` from usethis uses `# pkg 0.1.1` /
`# pkg (development version)` headings — keep that, do not convert).
- If no changelog exists (`NEWS.md`/`CHANGELOG.md`/`CHANGES.md`/
  `HISTORY.md`), **ask which name to create**. `NEWS.md` is the R convention;
  `CHANGELOG.md` is more common elsewhere.
- Insert the new section at the **top**, below header boilerplate:
  ```markdown
  ## [<new_version>] - <YYYY-MM-DD>

  ### Added
  - ...

  ### Changed
  - ...

  ### Fixed
  - ...
  ```
  Only include subheadings (`Added`/`Changed`/`Deprecated`/`Removed`/
  `Fixed`/`Security`) that apply. Write the bullets yourself from the commit
  log/diff — summarizing *what changed and why* is judgment, not a regex.
- For a brand-new file add the Keep a Changelog preamble:
  ```markdown
  # Changelog

  All notable changes to this project will be documented in this file.

  The format is based on [Keep a Changelog][kac],
  and this project adheres to [Semantic Versioning][semver].

  [kac]: https://keepachangelog.com/en/1.1.0/
  [semver]: https://semver.org/spec/v2.0.0.html
  ```
  (For non-SemVer ecosystems say "adheres to the versioning scheme of
  <ecosystem>" instead.)
- Never rewrite past version headers; `apply` excludes changelog files.

## Gotchas

- **Pathspec exclusions use `:(exclude,glob)…`.** The `:!path` shorthand
  mis-parses patterns starting with `_` on git 2.34 (`Unimplemented pathspec
  magic '_'`), and a plain `:(exclude)NEWS.md` matches only the repo root —
  nested changelogs/lockfiles would be rewritten. The `glob` magic with a
  leading `**/` matches at every depth.
- **First-bump baseline.** If the version line has never changed in history,
  `scan` falls back to the first commit, so the range is the whole project.
  Re-read the log rather than trusting range size once real releases exist.
- **`git log -G` heuristics.** The "version line" pattern for `rust`/`python`
  (`^version =`) can also match `[dependencies.foo] version = …` tables; if
  the reported "last bump" looks wrong, trust the log.
- **Bash 3.2.** macOS ships bash 3.2; the script avoids `mapfile`,
  associative arrays and bare empty-array expansion under `set -u`. Keep it
  that way (run `scripts/test_version_bump.sh` with `/bin/bash`).

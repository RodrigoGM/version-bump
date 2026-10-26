---
name: version-bump
description: Bump a project's version in whatever format its ecosystem uses (SemVer for Node/Rust, PEP 440 for Python, R's X.Y.Z.9000 development versions, RubyGems, Go module tags and /vN paths, Maven -SNAPSHOT, Composer, plain VERSION files) and update every place that must agree. Use whenever the user asks to bump the version, cut or prepare a release, "what should the next version be" / "patch or minor?", prepare a NEWS/CHANGELOG entry, or says /version-bump, even with no other detail. Computes and writes versions only; never commits, tags or pushes.
---

`scripts/version_bump.sh` does the mechanical, deterministic work: detect the
ecosystem, read the current version, **parse it against that ecosystem's
grammar, compute the candidate next versions**, check secondary version
locations, and write the version field. You do the judgment calls: choosing
which kind of bump fits the changes, confirming with the user, and writing
the changelog prose. Never compute a new version by hand — the script's
candidates are the only source.

Run it as `bash <skill_dir>/scripts/version_bump.sh ...`, where `<skill_dir>`
is the directory containing this SKILL.md (it is not in the user's repo, so a
bare `scripts/...` path will not resolve). Call it `$VB` below.

Read `references/conventions.md` before assessing a bump, at least the
section for the detected ecosystem. It defines each ecosystem's version
format and bump rules (Python's PEP 440, R's usethis arithmetic, Cargo's
0.x rule, Go's `/vN` path rule, …) and is the source of truth; do not apply
generic SemVer judgment from memory.

## Invoked with no extra instructions

A bare `/version-bump`, or just "bump the version" / "cut a release", is not
missing information; it is the whole task. Start at step 1 now, treating the
current directory as the repo (the script finds the root itself). Do not ask
what to bump or which project; `scan` is read-only and its output says
whether there is anything to do. Ask only what the workflow calls for once
you hold real output: confirming the bump (step 3), naming a new changelog
file (step 6), resolving a mismatch (step 1), or — if `scan` printed a
`NOTE: also found: …` line — which ecosystem the user means.

If `scan` fails (not a git repo, no commits, no recognizable manifest), hand
the message back plainly with the one next step it names (e.g. "cd into the
project, then re-run"); do not guess a project type or ask the user to
restate the request. If it exits 3 (`UNSUPPORTED: …`), report the reason and
ask for the exact new version or the fix; never improvise a format.

## Workflow

1. **Scan** (read-only, safe any time):
   ```bash
   bash <skill_dir>/scripts/version_bump.sh scan
   ```
   It reports: detected type and scheme; current version; **bump candidates**
   (`patch -> 1.2.4`, …, with `[user-only]` marks); commits since the last
   bump; a public-API diff; other tracked lines containing the version
   (`file:line:text`); changelog status; and the **out-of-sync check**.

   **If it prints MISMATCH or UNPARSEABLE (exit 2), stop.** Show the user both
   values and which file is authoritative (conventions.md), and ask them to
   fix the secondary location or confirm `--force`. Don't pick one silently.
   `apply` enforces this too and exits non-zero.

2. **Assess which kind** from the commit log and API diff, using the rules
   for this ecosystem in conventions.md (e.g. Cargo `0.y.z`: breaking ⇒
   `minor`). The API-diff is a hint; trust the log over it. Pick only among
   the kinds `scan` marked as available; a kind shown as `n/a` is refused by
   the script for a reason it prints.

3. **Confirm with the user** via `AskUserQuestion`: current version, your
   assessed kind and reasoning, the resulting version (copied from `scan`),
   and the files that will change (run `apply … --dry-run` to get them).
   Let the user accept, change the kind, or give an explicit version.

   **Never propose `major` or `release`** (leaving a pre-release/SNAPSHOT) on
   your own; offer them only if the user asks, and ask even when the
   ecosystem would technically allow it. Starting a new pre-release series
   always needs an explicit version from the user.

4. **Apply** only after confirmation:
   ```bash
   bash <skill_dir>/scripts/version_bump.sh apply <old> <new> [--dry-run] [--also=<path> …] [--force]
   ```
   It validates `<new>` against the ecosystem's grammar (so a SemVer-shaped
   string for a Python project is rejected with the correct spelling),
   edits the declared version field and known secondary locations, and
   prints each file it touched. Other occurrences listed by `scan` are
   rewritten **only** if the user approves them and you pass `--also=<path>`
   for each; dependency pins of other packages, dates and fixtures must be
   left alone. `--force` only when the user explicitly said to bump despite
   an unresolved mismatch.

   If the script exits 3 (version outside the grammar: build metadata,
   non-normalized spelling, dynamic or inherited version, …) say so and stop;
   don't work around it. This skill never runs `git commit`, `git tag` or
   `git push`; for ecosystems where the tag *is* the release (Go,
   Composer), tell the user to tag it themselves.

5. **Verify**:
   ```bash
   bash <skill_dir>/scripts/version_bump.sh verify <old> <new>
   ```
   Confirms the manifest and secondary locations now say `<new>` and lists
   any remaining whole-token mentions of `<old>`. Then show `git diff` so
   the user can review before committing. Lockfiles are regenerated by the
   package manager, not edited; relay the script's note.

6. **Record the change** in the changelog — see conventions.md for the
   template, matching an existing file's style, and the question to ask when
   no changelog exists yet. Past entries are never rewritten.

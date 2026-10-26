# version-bump todo

Status as of 2026-10-26.

- [x] 1. **Installed copy was stale.** `~/.claude/skills/version-bump` was
      the pre-rewrite version. Backed up the old copy, then synced the
      repo working tree into it (excluding `.git` and `tasks/`). `diff -rq`
      shows identical. `~/.claude/skills/synced/...` is a separate managed
      copy and was left alone. Restart Claude Code to reload.
- [x] 2. **Permanent tests for the security fixes.** Added T10 to
      `scripts/test_version_bump.sh` (symlinked manifest refused,
      root-level dash-named `__init__.py` refused). 112 passed, 0 failed.
- [ ] 3. **Independent code review** of `scripts/version_bump.sh` (fresh
      eyes; the automated scan found two issues self-review missed).
- [ ] 4. **Verify against docs:** npm `^0.y.z` caret rule; bundler's path
      rule for dashed gem names; `semver.inc patch` on a pre-release (the
      script refuses instead of guessing).
- [ ] 5. **Test gaps:** real repos (only throwaway fixtures so far); bash 5;
      newer git; minified JSON; one-line POMs; Windows; README install
      steps end to end.
- [ ] 6. **Known limit:** Gradle unsupported (falls back to `generic`).
- [~] 7. **Release 1.0.0.** `VERSION` = `1.0.0` added (the skill's own scan
      reads it as `generic`/semver). Still to do: commit, `git tag v1.0.0`,
      push, GitHub release.
- [x] 8. **`tasks/lessons.md`** created.
- [x] 9. **80-column rule** (lessons.md, item 0). Docs, tests and scripts
      wrapped; 112/112 tests pass. Skipped by instruction: shell commands
      (README.md:35, SKILL.md:83) and 18 inline awk/perl program lines in
      `scripts/version_bump.sh`. Open: wrap those awk lines too?

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

## Open questions (awaiting decision)
- [ ] Q1. **Commit email.** All 4 pushed commits and the local `v1.0.0` tag
      carry the work email from the global git config. Choose: (1) leave it;
      (2) set a repo-local `user.email` (personal or GitHub no-reply
      address) for future commits only; (3) also rewrite history and
      force-push (changes hashes; old email stays in caches and clones).
- [x] Q2. **Push the `v1.0.0` tag.** Created on `4a72a32` and pushed. It
      carries the work email (see Q1).
- [ ] Q3. **Create a GitHub release for `v1.0.0`?** A release is a page on
      top of a tag: release notes, "Latest" badge, source archives,
      optional files, watcher notifications.
      (`gh release create v1.0.0 --notes "..."`).
- [x] Q4. **Inline awk/perl lines:** keep the one-liner exception; do not
      wrap them.
- [x] Q5. **`tasks/` stays in the public repo** (sanitized, reviewed).
- [ ] Lesson to add to `tasks/lessons.md`: audits must include git
      metadata (author/committer emails, tag taggers), not just files.

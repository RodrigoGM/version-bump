# version-bump

A [Claude Code](https://claude.com/claude-code) skill that bumps a project's
version the way its ecosystem expects, and keeps every place that must agree
in sync.

The detected project type picks both the version format and the bump rules, so a
Python project gets PEP 440 (`1.2.0rc2`), an R package gets `X.Y.Z.9000`
development versions, a Go module gets `/vN` path handling, and so on. A script
computes the candidate versions; Claude only decides which kind of bump fits the
changes.

| Ecosystem | Scheme |
|---|---|
| Node, Rust, plain `VERSION` | SemVer |
| Python | PEP 440 |
| R | `X.Y.Z` / `X.Y.Z.9000` (usethis) |
| Ruby | RubyGems |
| Go | Go modules (`vX.Y.Z`, `/vN`) |
| Maven | `-SNAPSHOT` |
| PHP | Composer (tag-derived) |

Safety rules: it asks before writing, refuses to proceed if version locations
disagree, stops on versions it can't parse, never proposes a major bump on its
own, and never commits, tags or pushes. Details are in
[`references/conventions.md`](references/conventions.md).

## Install

Requires `bash`, `git` and `perl`.

For all your projects:

```bash
git clone https://github.com/RodrigoGM/version-bump ~/.claude/skills/version-bump
```

For a single project, clone into `<project>/.claude/skills/version-bump`
instead.

Restart Claude Code, then run `/version-bump` from inside a git repository, or
just ask to "bump the version".

## Test

```bash
bash scripts/test_version_bump.sh
```

## License

BSD 3-Clause. See [`LICENSE`](LICENSE).

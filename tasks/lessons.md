# Lessons

Patterns from user corrections. Review at session start.

0. **80 column limit** limit all lines to 80 columns, no exceptions
1. **Generic skills must not name real projects.** Use placeholders (`<mypkg>`)
   and grep for project names before any publication audit.
2. **A narrow secret scan is not an audit.** The first pass only searched for 
   key/token/password words and a few formats, then I reported "clean". Scan 
   also for emails, URLs, IPs, names, usernames, home paths, high-entropy 
   strings and PHI terms, and say what was NOT checked (e.g. git history).
3. **Do not push, tag or release without an explicit go for that specific 
   action.** Approval to publish the repo did not cover later commits; each push
   was confirmed first.
4. **Re-audit after files change.** The files were rewritten after the first 
   audit, so the audit had to be repeated before publishing.
5. **Shell pitfalls hit here:** `local` outside a function aborts under bash 
   3.2; pass `--` before paths to `perl`; `cat > file` follows symlinks; a 
   persistent `cd` changes later relative paths, so use absolute paths.
6. **Check the installed copy, not just the repo.** The skill actually loaded by
   Claude Code lived in `~/.claude/skills/` and was stale after the repo was 
   updated.
   

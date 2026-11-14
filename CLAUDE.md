# KeyPoint OSC

## Syncing between Macs

This project is worked on from two Macs, kept in sync through GitHub. There are TWO git repos:

- this folder (KeyPoint OSC app): github.com/BasilChessman/KeyPoint-OSC
- `companion-module/` (Companion module): github.com/BasilChessman/companion-module-rustedroof-keypoint-osc.
  It's gitignored here, so git commands in this folder never touch it: run them in both.

**Start of session:** `git pull --ff-only` in this folder AND in `companion-module/`, plus
`git fetch --tags` in both. If a pull won't fast-forward, stop and investigate before merging
or resetting: compare with `git diff main origin/main` and `git log main...origin/main`.

**End of session:** commit and `git push` in both repos (and `git push --tags` if a tag was made
outside `scripts/release.sh`). Check `git status -sb` shows neither repo ahead or behind.

**Never rewrite pushed history** (no amend, rebase or filter of pushed commits, no `push --force`,
no moving pushed tags). The other Mac can't follow it: its next pull diverges. If a rewrite is
truly unavoidable, tell the user, so that the other Mac runs `git fetch && git reset --hard origin/main`
and `git fetch --tags --force` in that repo before any other work.

Commits must use the GitHub noreply identity, set in each repo on each Mac:
`git config user.name BasilChessman` and
`git config user.email 45463654+BasilChessman@users.noreply.github.com`.
Check with `git config user.email` before the first commit of a session.

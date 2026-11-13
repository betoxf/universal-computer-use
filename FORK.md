# This fork

`betoxf/universal-computer-use` is agent-desktop from [Vercel Labs](https://github.com/vercel-labs/agent-desktop), plus
UCU: everything that lets agents work on a Mac without getting in the user's way. Its history includes agent-desktop's,
so upstream merges in as usual.

| Where | What it holds |
| --- | --- |
| `betoxf/universal-computer-use`, branch `main` | Our product: upstream, our contributions, and `ucu/`. Installs clone and update from here. |
| `betoxf/agent-desktop`, branch `main` | An exact copy of upstream. Nothing is committed here. |
| `betoxf/agent-desktop`, branches `contrib/<topic>` | One improvement for upstream, cut from upstream's `main`, following upstream's `AGENTS.md`. |

`betoxf/agent-desktop` stays a GitHub fork of upstream so that `contrib/<topic>` branches can open PRs there. Its `ucu`
branch held UCU until it moved here and is no longer updated.

## Adding an improvement

Anything upstream might want starts on a `contrib/<topic>` branch and merges into `main` here. Open the upstream PR from
that branch, pushed to `betoxf/agent-desktop`, whenever it's ready: `main` doesn't wait for it. Work that only makes
sense for UCU goes straight to `ucu/`.

## Staying up to date

```bash
git remote add upstream https://github.com/vercel-labs/agent-desktop.git   # once
git fetch upstream
git checkout main && git merge upstream/main
```

`ucu/` keeps UCU's own README, tests and license notice. It runs on this repo's engine. The repository's front page on
GitHub is `.github/README.md`, so the root `README.md` stays upstream's and merges without conflicts. `main` also
carries upstream's open PR #436, so that chats on different apps don't wait for each other, until upstream merges it.

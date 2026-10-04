# GitFrame

> Understand code in its exact Git context.

GitFrame is a terminal workspace for reviewing Git changes, browsing source,
and exploring history.

“Frame” is the Git context that gives code its meaning: the repository,
worktree, file path, current state, commits, and comparison basis. GitFrame
preserves that frame so you always know exactly what you are viewing or
changing.

<!-- Add a release screenshot or short demo here. -->

## Highlights

- Switch repositories and branches.
- Navigate with Vim-style keys.
- Review unified or side-by-side diffs. (Changes, History, Compare)
- Stage, commit, and sync changes. (Changes)
- View full source files and explore the repository. (Repository)
- Inspect commits and their changed files. (History)
- Compare branches using merge-base. (Compare)

## Four working views

GitFrame separates current changes, repository browsing, commit history, and
branch comparison into four working views.

| Key | View | Focus |
| --- | --- | --- |
| `1` | **Changes** | Working tree and index |
| `2` | **Repository** | Repository source |
| `3` | **History** | Commits and commit ranges |
| `4` | **Compare** | Current `HEAD` and selected Base branch |

## Getting started

Git **2.45.1 or newer** must be on your `PATH`. Check with `git --version`;
see [requirements and Git updates](docs/guide.md#requirements) if needed.

Run GitFrame inside a Git worktree to review staged and unstaged changes:

```sh
gitframe
```

In the main views, press `?` for help or `q` to quit. Run `gitframe --help`
to see the available command-line options.

See the [guide](docs/guide.md) for installation, usage, and development
instructions.

## Design boundaries

GitFrame is intentionally scoped and does not aim to provide:

- a full text editor or IDE;
- a replacement for every Git command;
- an interactive rebase or commit-graph workbench;
- a provider-specific Git hosting client or web interface;
- native Windows support.

## Architecture

GitFrame is written in Zig and built on:

- [Chasen](https://github.com/hiroaqii/chasen) for the terminal runtime and
  effect boundary;
- [Chasen UI](https://github.com/hiroaqii/chasen-ui) for reusable TUI
  components;
- [flow-syntax](https://github.com/neurocyte/flow-syntax) for optional syntax
  highlighting.

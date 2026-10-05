# GitFrame

> Understand code in its exact Git context.

GitFrame is a terminal workspace for reviewing Git changes, browsing source,
and exploring history.

“Frame” is the Git context that gives code its meaning: the repository,
worktree, file path, current state, commits, and comparison basis. GitFrame
preserves that frame so you always know exactly what you are viewing or
changing.

https://github.com/user-attachments/assets/38aef9d7-db65-48eb-89bb-c76b498770dd

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

## Installation

GitFrame can be installed with Homebrew or mise, or built from source.
Homebrew and mise use prebuilt binaries from
[GitHub Releases](https://github.com/hiroaqii/gitframe/releases), so no Zig
compiler is required for those methods.

### Requirements

The prebuilt binaries support the following platforms:

| Platform | Requirements |
| --- | --- |
| macOS | macOS 15 or newer on Apple Silicon |
| Linux | x86_64, kernel 5.15 or newer, glibc 2.35 or newer |

GitFrame runs in an interactive terminal and requires **Git 2.45.1 or newer**
on your `PATH`. Check the installed version with `git --version`.
Homebrew installs Git as a dependency; install Git separately when using mise
or building from source. For Git updates and startup failures, see
[requirements troubleshooting](docs/guide.md#requirements).

### Homebrew

With [Homebrew](https://brew.sh/) installed, run:

```sh
brew install hiroaqii/tap/gitframe
```

On Apple Silicon, use native ARM Homebrew.

To update GitFrame:

```sh
brew update
brew upgrade hiroaqii/tap/gitframe
```

### mise

With [mise](https://mise.jdx.dev/) installed and activated in your shell, run:

```sh
mise use -g github:hiroaqii/gitframe@latest
```

This makes GitFrame available globally in shells using mise. To update:

```sh
mise upgrade github:hiroaqii/gitframe
```

By default, mise waits 24 hours before selecting a newly published release
with `@latest`. See mise's
[minimum release age setting](https://mise.jdx.dev/configuration/settings.html#minimum_release_age)
for details.

### From source

See the guide's [source build instructions](docs/guide.md#from-source) to
build GitFrame with Zig and install the binary.

### Check the installation

Check that GitFrame is available:

```sh
gitframe --version
gitframe --help
```

## Getting started

Run GitFrame inside a Git worktree to review staged and unstaged changes:

```sh
gitframe
```

In the main views, press `?` for help or `q` to quit. Run `gitframe --help`
to see the available command-line options.

See the [guide](docs/guide.md) for usage, configuration, troubleshooting,
and development instructions.

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

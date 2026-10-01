# GitFrame guide

This guide covers installation, everyday use, optional configuration, and
development.

- [Installation](#installation)
- [Basic usage](#basic-usage)
- [Working views](#working-views)
- [Configuration (optional)](#configuration-optional)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

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

GitFrame runs in an interactive terminal and requires Git on your `PATH`.
Homebrew installs Git as a dependency; install Git separately when using mise
or building from source.

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

Install Zig **0.16.0** and Git on Linux or macOS. Download **Source code
(tar.gz)** or **Source code (zip)** from the
[latest release](https://github.com/hiroaqii/gitframe/releases/latest),
extract the archive, and open a terminal in the extracted directory.

Choose one of the following builds.

#### With Tree-sitter (default)

```sh
zig build -Doptimize=ReleaseSafe
```

Tree-sitter syntax highlighting is enabled by default. Zig downloads and
builds the required dependencies automatically; a separate Tree-sitter
installation is not needed.

#### Without Tree-sitter

```sh
zig build -Doptimize=ReleaseSafe -Dsyntax-provider=none
```

Choose this build for a smaller binary and shorter compilation times,
especially when building from scratch. It omits Tree-sitter and its language
parsers. Syntax highlighting in diffs and source views is disabled; added and
removed lines still use their diff colors.

#### Install the binary

Both builds produce `zig-out/bin/gitframe`. Check it and install it into your
local binary directory:

```sh
./zig-out/bin/gitframe --version
mkdir -p "$HOME/.local/bin"
install -m 755 zig-out/bin/gitframe "$HOME/.local/bin/gitframe"
```

If `$HOME/.local/bin` is not on your `PATH`, add this line to your shell's
startup file, such as `~/.zshrc` or `~/.bashrc`, and open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

### Check the installation

Check that GitFrame is available:

```sh
gitframe --version
gitframe --help
```

## Basic usage

### Start in a repository

```sh
cd /path/to/your/repository
gitframe
```

GitFrame opens Changes with staged and unstaged changes. It uses built-in
defaults, and Changes refreshes automatically every three seconds.

Press `?` for the current view's controls, or `q` to quit from a main view.
Prompts and dialogs show their own controls; `Esc` closes or cancels the
current interaction.

### Review, stage, and commit

1. Select a file with `j` / `k` or the arrow keys to inspect its diff.
2. Press `u` to switch between unified and side-by-side diffs. Use `Tab` to
   move focus between the file tree and the diff.
3. With the file tree focused, press `Space` to stage or unstage a file.
   With the diff focused, `Space` acts on the current hunk.
4. Press `c` to open the commit panel. Enter a subject and, optionally, use
   `Tab` to move to the message body. Press `Ctrl+s` or `Ctrl+Enter` to commit
   the staged changes. Plain `Enter` edits the message; it does not submit.
5. Press `P` to push. Check the branch and remote shown in the confirmation
   before proceeding.

Stage and unstage change the index, which holds the content for your next
commit. They do not discard your working files. See
[Changes](#changes) for other Git operations.

### Search, select, and copy

Use `f` to find a file and `/` to search the displayed diff or source. In
History, `/` searches the diff, not commit messages. With a text search
active, `n` moves to the next match and `N` to the previous one.

With the diff or source pane focused, press `V` to begin a line selection,
extend it with `j` / `k` or the up/down arrows, and press `y` to copy it.
Press `Esc` to clear the selection. You can also drag across text with the
mouse, release the button, and use `y` to copy the completed selection.

In Repository, `Y` copies selected code together with its repository, file,
and line information. In History and Compare, this context copy is also
available for source selections in side-by-side mode and includes the
before/after commit IDs and the selected side. Unified diff selections use
diff text. Without a selection, `Y` in a diff pane copies the current hunk.

### Switch repositories and branches

Press `R` from any working view to open the repository picker. Select a
recent repository and press `Enter`, or press `p` to enter a directory path.
Use `/` to filter the list. In list mode, `d` removes an entry from recent
history; it does not delete the repository.

You can also open a directory containing multiple repositories. GitFrame
looks for repositories in its immediate child directories and lets you
choose one. This also works when starting GitFrame in that parent directory.

Press `b` to choose an existing local branch. GitFrame checks out the selected
branch, or opens its existing worktree if it is checked out elsewhere. This
changes the active working context. To compare against a branch without
checking it out, use [Compare](#compare).

### Command-line examples

Run `gitframe --help` for all options. For manual refresh or no transition
animations:

```sh
gitframe --no-watch
gitframe --no-transition
```

Press `r` to refresh the current view manually. You can also open a patch file
or a commit-range diff:

```sh
gitframe ./change.patch
gitframe --range main...HEAD
```

These open in Changes as read-only diff sources: stage, unstage, and discard
are unavailable. Patch files can be opened outside a repository; commit
ranges require a Git worktree. Specify one source per invocation.

## Working views

| Key | View | What you are viewing |
| --- | --- | --- |
| `1` | Changes | Current working-tree and index changes |
| `2` | Repository | Full source files in the current worktree |
| `3` | History | A commit or a selected range of commits |
| `4` | Compare | Committed changes from a Base branch's merge base to `HEAD` |

### Changes

Changes is where you prepare your next commit. Stage or unstage individual
files and hunks using [the basic workflow](#review-stage-and-commit).
`Space` on a directory in the file tree acts on that directory's eligible
files. Binary files and some file states do not support hunk operations;
use the file-level action when available.

In the diff pane, `J` / `K` moves between hunks and `Enter` folds or unfolds
the current hunk. `[` / `]` moves between files. Press `B` to show or hide
the file tree, and `<` / `>` to adjust its width.

Press `v` to toggle a file's reviewed mark and `H` to hide or show reviewed
files. These marks track your review during the current session; they do
not stage files or create commits. `F` cycles the file filter. If files seem
to be missing, check both the filter and whether reviewed files are hidden.

Other operations are available from Changes. Push and pull are also available
from Repository, using the same keys, confirmation, cancellation, and retry flow:

| Key | Operation | Behavior |
| --- | --- | --- |
| `A` | Amend | Edit the last commit's message and include the current index; submission opens a confirmation because this rewrites history |
| `D` | Discard | Discard unstaged tracked changes in the selected file after confirmation; directories, untracked files, and conflicts are unsupported |
| `s` | Create stash | Choose all changes or staged changes and an optional message |
| `S` | Stashes | Inspect saved stashes and apply or drop a selected entry after confirmation |
| `P` | Push | Show the destination and confirm before pushing the current branch |
| `U` | Pull | Fetch the upstream remote, then fast-forward the current branch when it is behind |

Applying a stash keeps the saved entry and does not restore its original
staged/unstaged classification. Dropping a stash removes that saved entry;
it does not discard the current worktree's changes.

Pull requires an upstream and supports fast-forward only. Local changes,
including staged changes and untracked files, are allowed when Git can
preserve them. Git refuses updates that would overwrite local changes;
GitFrame does not automatically stash them. If there are no incoming
commits, Pull succeeds without changing the branch, even if it is ahead.
Resolve divergence with Git before retrying. Remote operations use your
existing Git authentication setup; see [Troubleshooting](#troubleshooting)
if one fails.

### Repository

Press `P` to push or `U` to pull the current repository's branch while browsing
either the file tree or source. These operate on the repository, not the selected
file, and do not require opening Changes first. Custom push/pull key bindings
apply on both pages. Search and selection modes retain their input ownership.

Confirmation, progress, and errors stay on the page where the action started.
On both Changes and Repository, page switching is blocked while a confirmation
is open, a push/pull is running (including cancellation), or an error dialog is
open. Close the dialog and wait for the action to finish before switching pages.
After push, branch synchronization information refreshes; after pull, the file
tree, source content, and Changes data refresh when their page is displayed.

Repository shows full source files, including files with no changes. Switch
from Changes with `2` to open the selected file's current source when that
path is available. Switching back with `1` selects the corresponding file
in Changes when it is present there.

Use `Tab` to focus the tree or source, `Enter` to expand or collapse a
directory, and `f` to find a file. `F` switches between all files and changed
files. In the source pane, use `/` to search, `[` / `]` to move between files,
and `L` to toggle line numbers. Type `:42` and press `Enter` to go to source line 42.

Press `e` to open the selected file in an external editor. GitFrame returns
to the view when that editor command exits. Editor discovery checks `VISUAL`,
then `EDITOR`, then `nvim`, `vim`, and `vi` on your `PATH`. See
[Editor](#editor) to choose an explicit command.

### History

History shows commits, details for the selected commit, and its changed
files. Press `Enter` on a commit to open its diff within History. From the
diff, press `m` to select commits again.

To inspect a range, press `Space` on a commit to set an anchor, move to the
other endpoint, and press `Enter`. The highlighted span identifies the
selected commits. These ranges stay in History; they do not replace the
live Changes view.

Use `Tab` / `Shift+Tab` to move between panes. With commit details focused,
`y` copies the commit or range details. Diff navigation, selection, and
copying work as described in [Basic usage](#basic-usage).

### Compare

Compare shows the difference from the merge base of the selected Base branch
and the current `HEAD` to `HEAD`, using the same comparison basis as
`git diff BASE...HEAD`.

Press `m` to choose the Base branch. This changes the comparison without
checking out that branch. Working-tree and index changes belong in Changes
and are not included here.

Use `f` to find a changed file, `Tab` to focus the file tree or diff, and `u`
to switch diff layouts. As in Changes, `v` marks a file reviewed and `H`
hides or shows reviewed files. Press `r` to refresh the comparison.

## Configuration (optional)

GitFrame works without a configuration file. To customize it, create
`~/.config/gitframe/config.toml`, or
`$XDG_CONFIG_HOME/gitframe/config.toml` if `XDG_CONFIG_HOME` is set. This path
is used on both Linux and macOS. Add only the sections you need and restart
GitFrame after editing.

### Automatic refresh

These are the defaults:

```toml
[reload]
auto = true
interval_seconds = 3
```

The interval accepts whole seconds from `1` to `60`. Set `auto = false` for
manual refresh with `r`. The command-line options `--watch` and `--no-watch`
override `auto` for that invocation.

### Editor

To open Neovim at the selected line:

```toml
[editor]
argv = ["nvim", "+{line}", "{path}"]
```

For VS Code, use this section instead:

```toml
[editor]
argv = ["code", "--wait", "--goto", "{path}:{line}:{column}"]
```

An explicit `argv` takes precedence over `VISUAL` and `EDITOR`. Arguments are
passed directly to the program, without a shell. `{path}` is required;
`{line}`, `{column}`, and `{repo_root}` are also supported. The editor runs
from the repository root. A GUI editor should wait until editing finishes
before its command exits, as `--wait` does in the VS Code example.

### Saved state

Recent repositories are stored separately in
`~/.local/state/gitframe/state.json`, or
`$XDG_STATE_HOME/gitframe/state.json` if `XDG_STATE_HOME` is set. This file is
managed by GitFrame; use the repository picker to remove recent entries.
Reviewed marks are not saved across application restarts.

## Troubleshooting

### The command is not found

Run `command -v gitframe` to check which executable your shell can find.
For a source installation, check the [PATH setup](#install-the-binary).
For mise, check that mise is activated in the current shell. For Homebrew,
follow its shell setup instructions. Open a new terminal after changing
your shell's startup file.

### GitFrame cannot load the configuration

The startup error names the configuration file. Check the TOML syntax,
setting names, and values against the examples above. Invalid configuration
stops startup. To return to defaults, rename the file temporarily and launch
GitFrame again.

### The editor does not open

Check that the editor executable is on your `PATH`, and that `VISUAL`,
`EDITOR`, or `[editor].argv` names the intended command. Use the explicit
`argv` form for arguments that contain spaces. Select an existing regular
file: directories, deleted files, and symbolic links cannot be opened by
this action.

### A Git operation is unavailable or fails

Read the footer message or error dialog for the reason. Stage and discard
need live working-tree changes, and some file states support only
file-level actions. Press `r` if GitFrame reports that its view is stale.

For commit failures, check Git's reported error, including author identity,
hooks, or signing setup. For push and pull failures, check the remote,
upstream, and your Git credential helper or SSH agent. If a push error dialog
offers `i` for an interactive retry, use it to run the operation in the
foreground. Pull requires an upstream and supports fast-forward only.
Local changes are allowed when Git can preserve them. If Git refuses an
update because it would overwrite local changes or cannot fast-forward,
resolve the reported problem with Git before retrying.

For an unresolved problem, open a
[GitHub issue](https://github.com/hiroaqii/gitframe/issues) with the output of
`gitframe --version`, your OS and terminal, the error message, and steps to
reproduce it.

## Development

Install Zig **0.16.0** and Git, then clone the repository:

```sh
git clone https://github.com/hiroaqii/gitframe.git
cd gitframe
zig build
zig build run
```

Zig fetches the dependencies pinned in `build.zig.zon`; no sibling checkouts
are required. The first build needs network access. The executable is
written to `zig-out/bin/gitframe`.

Pass application arguments after `--`:

```sh
zig build run -- --no-watch
```

The application starts in the command's working directory. Use `R` to open
another repository. For a smaller build without syntax highlighting, add
`-Dsyntax-provider=none` as described in
[Without Tree-sitter](#without-tree-sitter).

Run tests and check formatting:

```sh
zig build test
zig fmt --check build.zig build.zig.zon src
```

To test without the syntax provider, or focus on a matching test name:

```sh
zig build test -Dsyntax-provider=none
zig build test -Dsyntax-provider=none -Dtest-filter=parseArgs
```

Use `zig build --help` for additional build steps and options. Release
maintainers can find publishing instructions in
[GitHub Releases](https://github.com/hiroaqii/gitframe/blob/main/.github/RELEASING.md).

#!/bin/sh
# Exercise the actual CLI without starting an interactive terminal.
set -eu

gitframe=$1
case "$gitframe" in /*) ;; *) gitframe="$PWD/$gitframe" ;; esac
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/gitframe-startup.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
mkdir -p "$test_dir/bin" "$test_dir/config/gitframe"
# Supported Git must reach this error; unsupported Git must stop before it.
printf '[broken\n' > "$test_dir/config/gitframe/config.toml"
cat > "$test_dir/bin/git" <<'GIT'
#!/bin/sh
printf 'call\n' >> "$GITFRAME_TEST_CALLS"
[ "$#" -eq 1 ] && [ "$1" = --version ] || exit 77
printf '%s\n' "$GITFRAME_TEST_VERSION"
exit "$GITFRAME_TEST_EXIT"
GIT
chmod +x "$test_dir/bin/git"
export GITFRAME_TEST_VERSION='git version 2.45.0' GITFRAME_TEST_EXIT=0

fail() {
    printf 'startup test failed: %s\n' "$1" >&2
    cat "$test_dir/stdout" "$test_dir/stderr" >&2
    exit 1
}

check() {
    expected_status=$1 expected_stdout=$2 expected_stderr=$3 expected_calls=$4
    shift 4
    : > "$test_dir/calls"
    status=0
    PATH="$test_dir/bin" XDG_CONFIG_HOME="$test_dir/config" \
        XDG_STATE_HOME="$test_dir/state" GITFRAME_TEST_CALLS="$test_dir/calls" \
        "$gitframe" "$@" > "$test_dir/stdout" 2> "$test_dir/stderr" || status=$?
    [ "$status" -eq "$expected_status" ] || fail "exit $status, expected $expected_status"
    [ "$(wc -l < "$test_dir/calls" | tr -d ' ')" -eq "$expected_calls" ] || fail 'Git call count'
    for stream in stdout stderr; do
        if [ "$stream" = stdout ]; then expected=$expected_stdout; else expected=$expected_stderr; fi
        if [ -n "$expected" ]; then
            grep -F -- "$expected" "$test_dir/$stream" > /dev/null || fail "missing $stream: $expected"
        else
            [ ! -s "$test_dir/$stream" ] || fail "unexpected $stream"
        fi
    done
    if [ "$expected_stderr" != 'cannot load config' ] &&
        grep -F 'cannot load config' "$test_dir/stderr" > /dev/null; then
        fail 'configuration was read before rejecting Git'
    fi
}

check 1 '' 'Git 2.45.1 or later is required.' 1
grep -F 'Detected Git version: 2.45.0' "$test_dir/stderr" > /dev/null
check 0 'Usage:' '' 0 --help
check 0 'gitframe ' '' 0 --version

for version in 'git version 2.45.1' 'git version 2.45.1 (Apple Git-157)' 'git version 2.55.0'; do
    export GITFRAME_TEST_VERSION="$version"
    check 1 '' 'cannot load config' 1
done

export GITFRAME_TEST_VERSION='not a Git version'
check 1 '' 'Could not parse Git version output.' 1
export GITFRAME_TEST_VERSION='git version 2.55.0' GITFRAME_TEST_EXIT=7
check 1 '' '`git --version` did not exit successfully.' 1

chmod -x "$test_dir/bin/git"
check 1 '' 'Could not run `git --version`.' 0
rm "$test_dir/bin/git"
check 1 '' 'Git was not found in PATH.' 0
check 0 'Usage:' '' 0 --help
check 0 'gitframe ' '' 0 --version
printf 'Git startup CLI checks passed.\n'

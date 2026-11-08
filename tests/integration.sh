#!/usr/bin/env bash
#
# End-to-end tests for update-flatpak-cli.
#
# Everything runs inside a throw-away HOME with synthetic Flatpak installation
# trees, so this is safe to run on a machine that has real Flatpaks installed
# (nothing outside the scratch directory is touched).
#
# Usage:  tests/integration.sh [path-to-binary]
#         make integration

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/.." && pwd)
BIN=${1:-${BIN:-$REPO/bin/update-flatpak-cli}}

if [ ! -x "$BIN" ]; then
    echo "error: $BIN is not executable. Run 'make' first." >&2
    exit 1
fi
BIN=$(cd -- "$(dirname -- "$BIN")" && pwd)/$(basename -- "$BIN")

PASS=0
FAIL=0
CURRENT=""

if [ -t 1 ]; then GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else GRN=""; RED=""; DIM=""; RST=""; fi

section() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RST"; }
ok()   { PASS=$((PASS + 1)); printf '  %sok%s   %s\n' "$GRN" "$RST" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq()      { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi; }
assert_ne()      { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3" "expected anything but [$2]"; fi; }
assert_file()    { if [ -f "$1" ]; then ok "$2"; else bad "$2" "no such file: $1"; fi; }
assert_nofile()  { if [ ! -e "$1" ]; then ok "$2"; else bad "$2" "should not exist: $1"; fi; }
assert_has()     { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "[$2] not found in $1"; fi; }
assert_lacks()   { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3" "[$2] unexpectedly found in $1"; else ok "$3"; fi; }
assert_out()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3" "[$2] not in output"; fi; }
assert_mode()    { local mode; mode=$(stat -c '%a' "$1" 2>/dev/null); assert_eq "$mode" "$2" "$3"; }
assert_bash_ok() {
    local failed=0 f
    for f in "$@"; do bash -n "$f" 2>/dev/null || { failed=1; echo "       syntax error in $f" >&2; }; done
    if [ "$failed" -eq 0 ]; then ok "all generated launchers are syntactically valid bash"; else bad "generated launcher syntax"; fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fpcli-it-XXXXXX")
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

HOME_DIR=$WORK/home
SYS=$WORK/system
USR=$WORK/user
OUT=$WORK/out
FAKE=$WORK/fakebin
mkdir -p "$HOME_DIR" "$FAKE"

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# make_app <root> <app-id> <command> [arch] [branch]
make_app() {
    local root=$1 id=$2 cmd=$3 arch=${4:-x86_64} branch=${5:-stable}
    local dir="$root/app/$id/$arch/$branch"
    mkdir -p "$dir/3f9c1d2e"
    printf '[Application]\nname=%s\nruntime=runtime/%s/stable\nsdk=sdk/%s/stable\ncommand=%s\n\n[Context]\nshared=network;ipc;\n' \
        "${id##*.}" "$arch" "$arch" "$cmd" > "$dir/3f9c1d2e/metadata"
    ln -sfn 3f9c1d2e "$dir/active"
}

# make_desktop <root> <app-id> <exec-line>
make_desktop() {
    local root=$1 id=$2 exec=$3
    mkdir -p "$root/exports/share/applications"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "${id##*.}" "$exec" \
        > "$root/exports/share/applications/$id.desktop"
}

make_app "$SYS" org.example.Foo          "Foo.sh"
make_app "$SYS" org.example.Bar          "org.example.Bar"
make_app "$SYS" org.example.Baz          "baz_wrapper"
make_app "$SYS" org.purei.Play           "Play"
make_app "$SYS" net.openra.OpenRA        "openra"
make_app "$SYS" com.github.AmatCoder.mednaffe "mednaffe"
make_app "$SYS" org.example.Nocommand    ""
make_desktop "$SYS" org.example.Bar      "org.example.Bar %u"
make_desktop "$SYS" org.example.Foo      "Foo %f"

# A user-installed app, plus a pair where the user install shadows the system
# install of the same app id (as libflatpak's precedence rules require).
make_app "$SYS" org.example.Shadowed     "systemversion"
make_app "$USR" com.eteks.SweetHome3D    "SweetHome3D"
make_app "$USR" org.example.Shadowed     "userversion"

# A "real" system command that will collide with a generated launcher.
printf '#!/bin/sh\necho i am the real one\n' > "$FAKE/foo"
chmod +x "$FAKE/foo"

# A stand-in for the flatpak CLI which just prints its argv, so we can verify
# the generated launchers really forward arguments the way they claim to.
cat > "$FAKE/flatpak" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
EOF
chmod +x "$FAKE/flatpak"

# run <extra-args...>  -- invokes the tool in a hermetic environment
run() {
    env -i \
        HOME="$HOME_DIR" \
        PATH="${TESTPATH:-$OUT:$FAKE:/usr/bin:/bin}" \
        FLATPAK_SYSTEM_DIR="$SYS" \
        FLATPAK_USER_DIR="$USR" \
        "$BIN" "$@"
}

# ---------------------------------------------------------------------------
section "1. first run generates launchers"
# ---------------------------------------------------------------------------
out=$(run --bin-dir "$OUT" 2>&1); rc=$?

assert_eq "$rc" "0" "exits 0"
assert_out "$out" "Getting list of installed application/non-runtime packages" "prints the original's banner"
assert_out "$out" "Generating wrapper for org.example.Foo" "announces each app"

for name in foo bar baz play_emu openra openra-cnc openra-d2k mednaffe mednafen \
            sweethome3d userversion; do
    assert_file "$OUT/$name" "created launcher '$name'"
done
assert_nofile "$OUT/systemversion" "a user install shadows the system install of the same id"

assert_mode "$OUT/foo" "755" "launchers are created mode 0755"
assert_has "$OUT/foo" "AUTOGENERATED FILE! DO NOT EDIT!" "launcher carries the do-not-edit marker"
assert_has "$OUT/bar" 'args+=("@@u")' "URL app uses @@u forwarding tokens"
assert_has "$OUT/foo" 'args+=("@@")' "path app uses @@ forwarding tokens"
assert_lacks "$OUT/foo" '@@u' "path app does not use @@u"
assert_has "$OUT/openra-cnc" 'exec flatpak run --command=openra-cnc --file-forwarding "net.openra.OpenRA"' "secondary command passes --command"
assert_has "$OUT/mednaffe" '--file-forwarding "com.github.AmatCoder.mednaffe"' "primary launcher runs the app itself"
assert_has "$OUT/mednafen" '--command=mednafen' "mednaffe exposes its secondary command"
assert_has "$OUT/bar" 'unset LD_PRELOAD' "unsets LD_PRELOAD like the original"
assert_bash_ok "$OUT"/*

# ---------------------------------------------------------------------------
section "2. launchers actually forward arguments"
# ---------------------------------------------------------------------------
touch "$WORK/a file.txt"
mkdir -p "$WORK/sub"
touch "$WORK/sub/b.txt"

argv=$(cd "$WORK" && PATH="$OUT:$FAKE:/usr/bin:/bin" foo "a file.txt" --flag=1 2>&1)
expected_a=$(readlink -f "$WORK/a file.txt")
assert_out "$argv" "run" "invokes 'flatpak run'"
assert_out "$argv" "--file-forwarding" "passes --file-forwarding"
assert_out "$argv" "org.example.Foo" "names the app id"
assert_out "$argv" "@@" "emits @@ tokens"
assert_out "$argv" "$expected_a" "turns a relative path into an absolute one"
assert_out "$argv" "--flag=1" "passes non-path arguments through untouched"

# A URL-taking app must use the @@u token.
argv=$(cd "$WORK" && PATH="$OUT:$FAKE:/usr/bin:/bin" bar "a file.txt" 2>&1)
assert_out "$argv" "@@u" "URL app forwards with @@u"

# A secondary command launcher must reach the right command.
argv=$(cd "$WORK" && PATH="$OUT:$FAKE:/usr/bin:/bin" openra-cnc 2>&1)
assert_out "$argv" "--command=openra-cnc" "secondary launcher passes --command"
assert_out "$argv" "net.openra.OpenRA" "secondary launcher names the app"

# ---------------------------------------------------------------------------
section "3. re-running is idempotent"
# ---------------------------------------------------------------------------
before=$(ls "$OUT" | sort)
nafter_expected=$(printf '%s\n' "$before" | wc -l)
out=$(run --bin-dir "$OUT" 2>&1); rc=$?
after=$(ls "$OUT" | sort)

assert_eq "$rc" "0" "second run exits 0"
assert_eq "$before" "$after" "second run produces the same launcher set"
assert_out "$out" "Removed: $nafter_expected" "prunes all stale launchers before regenerating"
if printf '%s' "$out" | grep -qF "already exists in your PATH at \"$OUT/"; then
    bad "does not warn about its own freshly written launchers"
else
    ok "does not warn about its own freshly written launchers"
fi

# ---------------------------------------------------------------------------
section "4. stale cleanup is marker-aware"
# ---------------------------------------------------------------------------
printf '#!/bin/bash\n# AUTOGENERATED FILE! DO NOT EDIT!\nexit 0\n' > "$OUT/obsolete"
printf '#!/bin/sh\necho hand written\n' > "$OUT/handwritten"
out=$(run --bin-dir "$OUT" 2>&1)
assert_nofile "$OUT/obsolete" "removes a stale launcher it generated earlier"
assert_file "$OUT/handwritten" "leaves a hand-written file alone by default"

out=$(run --bin-dir "$OUT" --prune-all 2>&1)
assert_nofile "$OUT/handwritten" "--prune-all restores the original sledgehammer behaviour"

# A file we did not create must not be silently clobbered, even on a name clash.
printf '#!/bin/sh\necho precious\n' > "$OUT/foo"
out=$(run --bin-dir "$OUT" 2>&1); rc=$?
assert_out "$out" "Refusing to overwrite" "refuses to overwrite an unrecognised file"
assert_has "$OUT/foo" "precious" "kept the unrecognised file intact"
out=$(run --bin-dir "$OUT" --force 2>&1)
assert_has "$OUT/foo" "AUTOGENERATED FILE" "--force replaces it"

# ---------------------------------------------------------------------------
section "5. collision detection"
# ---------------------------------------------------------------------------
make_app "$SYS" org.example.DupA "duplicate"
make_app "$SYS" org.example.DupB "duplicate"
out=$(run --bin-dir "$OUT" 2>&1); rc=$?
assert_eq "$rc" "1" "exits non-zero on an unresolvable name collision"
assert_out "$out" 'was already claimed' "reports the collision"
assert_out "$out" 'CMD_REMAPPINGS' "tells the operator how to fix it"
rm -rf "$SYS/app/org.example.DupA" "$SYS/app/org.example.DupB"

# ---------------------------------------------------------------------------
section "6. PATH diagnostics"
# ---------------------------------------------------------------------------
TESTPATH="/usr/bin:/bin" run --bin-dir "$OUT" > "$WORK/o" 2> "$WORK/e"
assert_has "$WORK/e" "Could not find $OUT in PATH" "warns when the output dir is not in PATH"

out=$(TESTPATH="$OUT:$FAKE:/usr/bin:/bin" run --bin-dir "$OUT" 2>&1)
assert_out "$out" "higher precedence than these paths" "warns when it shadows system paths"
assert_out "$out" '/usr/bin' "names the shadowed system directory"

out=$(TESTPATH="$FAKE:/usr/bin:/bin:$OUT" run --bin-dir "$OUT" 2>&1)
if printf '%s' "$out" | grep -q 'higher precedence'; then
    bad "stays quiet when nothing shadowed comes after the output dir" "$out"
else
    ok "stays quiet when nothing shadowed comes after the output dir"
fi

# ---------------------------------------------------------------------------
section "7. dry run touches nothing"
# ---------------------------------------------------------------------------
rm -rf "$WORK/dryrun"
out=$(run --bin-dir "$WORK/dryrun" --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "--dry-run exits 0"
assert_nofile "$WORK/dryrun" "--dry-run creates no directory"
assert_out "$out" "[dry-run]" "reports what it would do"

# ---------------------------------------------------------------------------
section "8. listing and selection flags"
# ---------------------------------------------------------------------------
out=$(run --list 2>&1)
assert_out "$out" "openra-cnc" "lists secondary commands"
assert_out "$out" "play_emu" "lists remapped command names"
assert_out "$out" "sweethome3d" "lists user-installed apps"
assert_out "$out" "org.example.Foo/x86_64/stable" "lists the full ref"

out=$(run --list --no-user 2>&1)
if printf '%s' "$out" | grep -q sweethome3d; then
    bad "--no-user hides user-installed apps"
else
    ok "--no-user hides user-installed apps"
fi

out=$(run --list --no-system 2>&1)
assert_out "$out" "sweethome3d" "--no-system still sees the user installation"
if printf '%s' "$out" | grep -q 'org.example.Bar'; then
    bad "--no-system hides system-installed apps"
else
    ok "--no-system hides system-installed apps"
fi

# ---------------------------------------------------------------------------
section "9. default output directory"
# ---------------------------------------------------------------------------
defout=$HOME_DIR/.local/bin/flatpak
assert_nofile "$defout" "default output dir starts absent"
out=$(TESTPATH="$defout:/usr/bin:/bin" run 2>&1); rc=$?
assert_eq "$rc" "0" "runs with no arguments"
assert_file "$defout/bar" "defaults to ~/.local/bin/flatpak"
assert_has "$defout/bar" '--file-forwarding' "default location gets real launchers"

# ---------------------------------------------------------------------------
section "10. CLI contract"
# ---------------------------------------------------------------------------
run --help > "$WORK/h" 2>&1
assert_has "$WORK/h" "USAGE" "--help prints usage"
run --version > "$WORK/v" 2>&1
assert_has "$WORK/v" "update-flatpak-cli 1.0.0" "--version prints a version"
run --bogus-option > "$WORK/b" 2>&1; rc=$?
assert_eq "$rc" "2" "unknown option exits 2"
run positional > "$WORK/p" 2>&1; rc=$?
assert_eq "$rc" "2" "positional arguments exit 2"
run --bin-dir > "$WORK/m" 2>&1; rc=$?
assert_eq "$rc" "2" "a missing option value exits 2"

out=$(run --bin-dir / 2>&1); rc=$?
assert_eq "$rc" "1" "refuses to manage the filesystem root"
out=$(run --bin-dir "$HOME_DIR" 2>&1); rc=$?
assert_eq "$rc" "1" "refuses to manage the home directory itself"

out=$(run --bin-dir relative/path 2>&1); rc=$?
assert_eq "$rc" "2" "refuses a relative output directory (usage error)"

# ---------------------------------------------------------------------------
section "11. hostile metadata cannot escape the output dir"
# ---------------------------------------------------------------------------
make_app "$SYS" org.example.Evil "../../../../tmp/evil-escape"
out=$(TESTPATH="$OUT:/usr/bin:/bin" run --bin-dir "$OUT" 2>&1)
assert_out "$out" "Refusing to create a launcher" "rejects a command name containing '..'"
assert_nofile /tmp/evil-escape "nothing was written outside the output dir"
rm -rf "$SYS/app/org.example.Evil"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

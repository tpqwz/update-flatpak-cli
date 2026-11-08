# Configuration

The tool is deliberately no-argument by default, so there is no config file to
keep in sync. The two things you may want to change are compile-time tables in
`src/fpcli/naming.nim`.

## Adding a remapping

Use this when an app ships a command name that is ugly, ambiguous, or collides
with something you use. The tool tells you when it is needed:

```
ERROR: Wrapper name "/home/you/.local/bin/flatpak/play" was already claimed by
"org.purei.Play" and could not be mapped to "org.videolan.VLC". Please add a
CMD_REMAPPINGS entry (see docs/CONFIGURATION.md).
```

Add one line to `CmdRemappings`:

```nim
  CmdRemappings*: seq[(string, string)] = @[
    ("io.github.simple64.simple64", "simple64"),
    # ...
    ("org.videolan.VLC", "vlc-gui"),     # <- app id, name to expose
  ]
```

Then rebuild:

```console
$ make && ./bin/update-flatpak-cli
```

The remapping is applied **last**, so it overrides every heuristic (extension
stripping, reverse-DNS collapsing, lowercasing, wrapper-suffix stripping).

## Adding secondary commands

Some packages ship a GUI launcher plus genuinely useful command-line tools.
Each entry in `ExtraCmds` becomes its own launcher that passes
`--command=<name>` to `flatpak run`:

```nim
  ExtraCmds*: seq[(string, seq[string])] = @[
    ("com.github.AmatCoder.mednaffe", @["mednafen"]),
    # ...
    ("org.gnome.Builder", @["gnome-builder-cli"]),  # <- one or more names
  ]
```

Extra commands do not go through the naming heuristics: the name you write is
the name you get. They do share the app's `%u`-vs-`%f` forwarding decision,
since that is a property of the application, not of the sub-command.

To find out which secondary commands an app actually ships:

```console
$ flatpak run --command=sh org.example.App -c 'ls /app/bin'
```

## Pointing at a different installation

Useful for a chroot, a container image, an immutable distro with a non-standard
prefix, or a mounted backup:

```console
$ update-flatpak-cli --system-root /mnt/chroot/var/lib/flatpak \
                     --bin-dir /tmp/launchers --dry-run --list
```

`FLATPAK_SYSTEM_DIR` and `FLATPAK_USER_DIR` are honoured (this is what the
test suite uses), as is `XDG_DATA_HOME` for the user installation.

## Where to put the output directory in `$PATH`

**At the end.**

```bash
export PATH="$PATH:$HOME/.local/bin/flatpak"
```

Flatpak applications are third-party binaries. If their launchers come before
`/usr/bin`, an app that happens to be named `git` or `ssh` silently replaces a
trusted system command. The tool warns when it detects this ordering:

```
WARNING: /home/you/.local/bin/flatpak has a higher precedence than these paths
in your PATH. This may present a security risk by allowing flatpaks to override
trusted system commands: /usr/bin, /bin
```

Keeping generated launchers in their own directory (rather than
`~/.local/bin` itself) is what makes that ordering possible, and it means
`rm -rf ~/.local/bin/flatpak` is a complete uninstall.

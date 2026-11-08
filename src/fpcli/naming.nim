## Derivation of a good CLI command name from a Flatpak ref's metadata
## `command=` value.
##
## All the heuristics of the original Python tool are reproduced, in the same
## order, because the order is observable:
##
##   1. strip a script extension (`.sh`, `.js`, `.py`, `.pl`, `.rb`)
##   2. if the name is just the reverse-DNS app id, keep only the last
##      component (`com.github.tchx84.Flatseal` -> `Flatseal`)
##   3. lowercase it (`SweetHome3D` -> `sweethome3d`)
##   4. strip a `_wrapper` / `-wrapper` / `_launcher` / `-launcher` suffix
##      (`scummvm_wrapper` -> `scummvm`)
##   5. apply an explicit operator-supplied remapping for this ref
##
## Plus the built-in remapping and "extra command" tables, which exist because
## some packages ship genuinely poor wrapper names, or ship a GUI launcher
## plus genuinely useful secondary CLI tools.

import std/[options, strutils]

const
  ## Extensions stripped from derived command names.
  ScriptExts* = [".sh", ".js", ".py", ".pl", ".rb"]

  ## Suffixes stripped from derived command names.
  WrapperSuffixes* = ["_wrapper", "-wrapper", "_launcher", "-launcher"]

  ## Remappings for Flatpak packages that use less-than-ideal command names.
  ## Keyed by app id; the value is the command name we would rather expose.
  CmdRemappings*: seq[(string, string)] = @[
    ("io.github.simple64.simple64", "simple64"),   # ships `gui-wrapper.sh`
    ("org.godotengine.Godot3", "godot3"),          # would collide with Godot 4
    ("org.jdownloader.JDownloader", "jdownloader"),# ships `jd-wrapper`
    ("org.ppsspp.PPSSPP", "ppsspp"),               # ships `PPSSPPDL`
    ("org.purei.Play", "play_emu"),                # collides with SoX's `play`
  ]

  ## Secondary commands to expose, keyed by app id.  Each becomes its own
  ## launcher that passes `--command=<name>` to `flatpak run`.
  ExtraCmds*: seq[(string, seq[string])] = @[
    ("com.github.AmatCoder.mednaffe", @["mednafen"]),
    ("net.openra.OpenRA", @["openra-cnc", "openra-d2k"]),
    ("org.atheme.audacious", @["audtool"]),
  ]

proc remapFor*(appRef: string): Option[string] =
  for (appId, name) in CmdRemappings:
    if appId == appRef:
      return some(name)
  none(string)

proc extraCmdsFor*(appRef: string): seq[string] =
  for (appId, names) in ExtraCmds:
    if appId == appRef:
      return names
  @[]

proc stripScriptExt(command: string): string =
  ## `86Box.sh` -> `86Box`.  Uses the same rule as Python's `os.path.splitext`
  ## restricted to known script extensions.
  for ext in ScriptExts:
    if command.len > ext.len and command.toLowerAscii().endsWith(ext):
      return command[0 ..< command.len - ext.len]
  command

proc stripReverseDns(command, appRef: string): string =
  ## If the command *is* the app id, keep the last dotted component.
  if command.toLowerAscii() == appRef.toLowerAscii() and command.contains('.'):
    let parts = command.split('.')
    if parts.len > 0 and parts[^1].len > 0:
      return parts[^1]
  command

proc stripWrapperSuffix(command: string): string =
  ## Remove one trailing wrapper/launcher suffix, case-insensitively.
  let lower = command.toLowerAscii()
  for suffix in WrapperSuffixes:
    if lower.len > suffix.len and lower.endsWith(suffix):
      return command[0 ..< command.len - suffix.len]
  command

proc prepareCmdName*(command, appRef: string): string =
  ## Apply every configured transformation to derive the best command name for
  ## `ref`.  The input is never assumed to be a bare file name.
  var name = strip(command)
  name = stripScriptExt(name)
  name = stripReverseDns(name, appRef)
  name = name.toLowerAscii()
  name = stripWrapperSuffix(name)
  # An explicit remapping overrides every heuristic above.
  let remapped = remapFor(appRef)
  if remapped.isSome:
    name = remapped.get
  name

proc hasTraversal*(candidate: string): bool =
  ## True if `candidate` contains a `.` or `..` path element.
  ##
  ## Flatpak metadata legitimately uses paths relative to /app for `command=`
  ## (e.g. `bin/foo`), so a separator alone is not suspicious -- but a `..`
  ## element never is, and silently rewriting it would hide a malformed or
  ## hostile package.
  for element in candidate.split('/'):
    if element == ".." or element == ".":
      return true
  false

proc validateCommandName*(name: string): Option[string] =
  ## Reject anything that could escape the output directory, confuse the
  ## shell, or otherwise be a bad file name.  Returns an error message when
  ## the name is unusable, `none` when it is fine.
  ##
  ## This is the one place where untrusted input (package-controlled metadata)
  ## reaches a path that gets created, so it is deliberately strict:
  ## a command name must be a single, ordinary path component.
  if name.len == 0:
    return some("command name is empty")
  if name.len > 255:
    return some("command name is longer than 255 bytes")
  if name == "." or name == "..":
    return some("command name is a relative directory reference")
  for c in name:
    if c == '/':
      return some("command name contains a path separator")
    if c == '\0':
      return some("command name contains a NUL byte")
    if ord(c) < 32 or ord(c) == 127:
      return some("command name contains a control character")
  if name[0] == '-':
    return some("command name begins with '-' and would be parsed as an option")
  none(string)

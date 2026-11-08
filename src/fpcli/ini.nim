## Minimal, dependency-free reader for the "key file" (INI) dialect used by
## Flatpak metadata files and freedesktop.org `.desktop` entries.
##
## This implements the subset of GLib's GKeyFile behaviour that this tool
## needs: group headers, `key=value` pairs, `#`/`;` comments, blank lines and
## backslash line continuations.  Localized keys (`Name[de]=...`) are stored
## verbatim and are simply never looked up by this program.
##
## Safety notes (in the spirit of CERT C rules STR30-C / STR31-C / MSC24-C):
##   * All indexing is bounds-checked (Nim raises, it does not corrupt memory).
##   * Every loop terminates on malformed input; no unbounded rescan.
##   * No allocation is ever freed manually, so there are no double-free or
##     use-after-free classes of defect at all.

import std/[options, strutils, tables]

type
  KeyFile* = object
    groups: Table[string, Table[string, string]]

proc initKeyFile*(): KeyFile =
  KeyFile(groups: initTable[string, Table[string, string]]())

proc loadKeyFile*(data: string): KeyFile =
  ## Parse `data` into a KeyFile.  Malformed lines are ignored rather than
  ## treated as fatal: metadata supplied by a Flatpak package must never be
  ## able to abort the whole run.
  result = initKeyFile()

  var group = ""
  let rawLines = data.splitLines()
  var i = 0
  while i < rawLines.len:
    var line = rawLines[i]
    inc i

    # GKeyFile line continuations: a trailing `\` swallows the newline and the
    # leading whitespace of the following line.
    while line.len > 0 and line[^1] == '\\' and i < rawLines.len:
      line.setLen(line.len - 1)
      line.add(strip(rawLines[i], leading = true, trailing = false))
      inc i

    let trimmed = strip(line)
    if trimmed.len == 0:
      continue
    if trimmed[0] == '#' or trimmed[0] == ';':
      continue

    if trimmed.len >= 2 and trimmed[0] == '[' and trimmed[^1] == ']':
      group = trimmed[1 .. ^2]
      if not result.groups.hasKey(group):
        result.groups[group] = initTable[string, string]()
      continue

    let eq = trimmed.find('=')
    if eq <= 0 or group.len == 0:
      continue

    let key = strip(trimmed[0 ..< eq])
    let value = strip(trimmed[eq + 1 .. ^1])
    if key.len == 0 or result.groups[group].hasKey(key):
      continue  # first occurrence wins, matching GKeyFile semantics
    result.groups[group][key] = value

proc hasGroup*(kf: KeyFile, group: string): bool =
  kf.groups.hasKey(group)

proc getString*(kf: KeyFile, group, key: string): Option[string] =
  ## Return the unlocalized value of `key` in `group`, if present.
  if not kf.groups.hasKey(group):
    return none(string)
  if not kf.groups[group].hasKey(key):
    return none(string)
  some(kf.groups[group][key])

proc getStringOr*(kf: KeyFile, group, key, default: string): string =
  let v = kf.getString(group, key)
  if v.isSome: v.get else: default

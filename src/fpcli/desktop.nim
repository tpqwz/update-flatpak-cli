## Reading of freedesktop.org `.desktop` entries -- specifically, deciding
## whether a Flatpak application expects `--file-forwarding` arguments to be
## URLs (`%u`/`%U`) rather than bare paths (`%f`/`%F`).
##
## This mirrors the `wants_urls()` helper of the original Python tool, but does
## its own tokenisation instead of shelling out to / importing Python's shlex,
## so the binary has no interpreter dependency at all.

import std/[options, strutils]

import ./ini

type
  ShellWordsError* = object of CatchableError

proc shlexSplit*(s: string): seq[string] =
  ## Split a command line into words using POSIX-shell-like rules: runs of
  ## whitespace separate words, single quotes preserve everything literally,
  ## double quotes preserve everything except backslash-escaped `$ ` " \`
  ## and newline, and an unquoted backslash escapes the next character.
  ##
  ## Unbalanced quotes are not an error here -- the remainder is still
  ## returned, because a broken `.desktop` file should only cost us the
  ## `%u`-vs-`%f` distinction, never the whole run.
  var cur = ""
  var haveWord = false
  var quote = '\0'
  var i = 0

  while i < s.len:
    let c = s[i]
    inc i

    if quote == '\'':
      if c == '\'':
        quote = '\0'
      else:
        cur.add c
        haveWord = true
    elif quote == '"':
      if c == '"':
        quote = '\0'
      elif c == '\\' and i < s.len and s[i] in {'$', '`', '"', '\\', '\n'}:
        cur.add s[i]
        inc i
        haveWord = true
      else:
        cur.add c
        haveWord = true
    else:
      case c
      of ' ', '\t', '\n', '\r', '\v', '\f':
        if haveWord:
          result.add cur
          cur.setLen(0)
          haveWord = false
      of '\'', '"':
        quote = c
        haveWord = true
      of '\\':
        if i < s.len:
          cur.add s[i]
          inc i
        haveWord = true
      else:
        cur.add c
        haveWord = true

  if haveWord:
    result.add cur

proc execLine*(desktopFile: string): Option[string] =
  ## Return the raw `Exec=` value of a `.desktop` file, or `none` if the file
  ## is missing/unreadable/lacks the key.
  var text: string
  try:
    text = readFile(desktopFile)
  except CatchableError:
    return none(string)
  loadKeyFile(text).getString("Desktop Entry", "Exec")

proc commandlineWantsUrls*(commandline: string): bool =
  ## True if any word of `commandline` is exactly `%u` or `%U`
  ## (case-insensitively, matching the original tool's `x.lower() == '%u'`).
  for word in shlexSplit(commandline):
    if word.toLowerAscii() == "%u":
      return true
  false

proc desktopFileWantsUrls*(desktopFile: string): bool =
  ## True if `desktopFile` exists and its `Exec` line asks for URL arguments.
  let exec = execLine(desktopFile)
  if exec.isNone:
    return false
  commandlineWantsUrls(exec.get)

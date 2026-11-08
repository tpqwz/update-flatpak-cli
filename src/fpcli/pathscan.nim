## `$PATH` inspection: does the output directory actually come into play, and
## does putting it early in `$PATH` let Flatpaks shadow trusted system tools?
##
## This replaces `distutils.spawn.find_executable` from the Python original
## (which no longer exists in Python 3.12+).

import std/[options, os, strutils]

proc pathDirs*(pathEnv = getEnv("PATH")): seq[string] =
  ## The entries of `$PATH`, in order, with empty entries dropped.  A trailing
  ## slash is removed so string comparisons with a bin dir work.
  for entry in pathEnv.split(PathSep):
    if entry.len == 0:
      continue
    var dir = entry
    while dir.len > 1 and dir.endsWith(DirSep):
      dir.setLen(dir.len - 1)
    result.add dir

proc isExecutableFile(path: string): bool =
  try:
    if not fileExists(path) or dirExists(path):
      return false
    fpUserExec in getFilePermissions(path)
  except OSError:
    false

proc findExecutable*(name: string, dirs: seq[string]): Option[string] =
  ## First executable named `name` found along `dirs`.
  ##
  ## A `name` containing a separator is rejected rather than interpreted as a
  ## path: this lookup must never be able to walk outside `$PATH`.
  if name.len == 0 or name.contains(DirSep):
    return none(string)
  for dir in dirs:
    let candidate = dir / name
    if isExecutableFile(candidate):
      return some(candidate)
  none(string)

type
  PathReport* = object
    binDirIndex*: int            ## index of the output dir in $PATH, or -1
    missing*: bool               ## output dir is not in $PATH at all
    shadowedSystemDirs*: seq[string]  ## system dirs that come *after* ours

proc analyzePath*(binDir: string, dirs: seq[string]): PathReport =
  ## Decide where `binDir` sits relative to the rest of `$PATH`.
  ##
  ## `shadowedSystemDirs` lists the directories that follow `binDir` in
  ## `$PATH` and are not inside the user's home directory -- i.e. the places
  ## where trusted system commands live.  If any Flatpak launcher shares a name
  ## with one of those commands, the Flatpak wins, which is what the original
  ## tool warned about.
  result.binDirIndex = -1

  for idx, dir in dirs:
    if dir == binDir:
      result.binDirIndex = idx
      break

  if result.binDirIndex < 0:
    result.missing = true
    return

  let home = getHomeDir()
  for idx in result.binDirIndex + 1 ..< dirs.len:
    let dir = dirs[idx]
    # User-owned trees (home dir, or a distro that uses /home) are not a
    # security concern in the way /usr/bin and /bin are.
    if dir.startsWith(home) or dir.startsWith("/home/") or
       dir.startsWith("/Users/"):
      continue
    result.shadowedSystemDirs.add dir

## Discovery of installed Flatpak applications.
##
## The original Python tool asked libflatpak (via PyGObject) for
## `list_installed_refs_by_kind(APP)` and then read each ref's metadata with
## GKeyFile.  This module does the equivalent by walking the well-known
## on-disk layout directly, which removes the GObject/GIR dependency and makes
## the whole program a single self-contained binary:
##
##   <installation>/app/<app-id>/<arch>/<branch>/active -> <commit-dir>
##   <installation>/app/<app-id>/<arch>/<branch>/<commit>/metadata
##   <installation>/exports/share/applications/<app-id>.desktop
##
## Where <installation> is `/var/lib/flatpak` (system) or
## `$XDG_DATA_HOME/flatpak` (user).  Both locations honour the standard
## `FLATPAK_SYSTEM_DIR` / `FLATPAK_USER_DIR` overrides so the tool can be
## pointed at a scratch tree, which is what the test suite does.

import std/[algorithm, options, os, strutils, times]

import ./ini

type
  InstallationKind* = enum
    ikSystem = "system"
    ikUser = "user"

  Installation* = object
    kind*: InstallationKind
    root*: string

  AppRef* = object
    id*: string
    arch*: string
    branch*: string
    deployDir*: string        ## directory containing the live `metadata`
    command*: string          ## `[Application] command=` from metadata
    installation*: InstallationKind

const
  DefaultSystemRoot* = "/var/lib/flatpak"

proc defaultSystemRoot*(): string =
  let fromEnv = getEnv("FLATPAK_SYSTEM_DIR")
  if fromEnv.len > 0: fromEnv else: DefaultSystemRoot

proc defaultUserRoot*(): string =
  let fromEnv = getEnv("FLATPAK_USER_DIR")
  if fromEnv.len > 0:
    return fromEnv
  let xdgDataHome = getEnv("XDG_DATA_HOME")
  if xdgDataHome.len > 0:
    return xdgDataHome / "flatpak"
  getHomeDir() / ".local" / "share" / "flatpak"

proc applicationsDir*(installation: Installation): string =
  ## Where Flatpak exports the `.desktop` files visible to the host.
  installation.root / "exports" / "share" / "applications"

proc sortedSubdirs(path: string): seq[string] =
  ## Names of the immediate subdirectories of `path`, sorted for deterministic
  ## output.  Missing/unreadable directories yield an empty sequence.
  if not dirExists(path):
    return
  try:
    for kind, sub in walkDir(path, relative = true):
      if kind == pcDir:
        result.add sub
  except OSError:
    discard
  sort(result)

proc looksLikeDeployDir(candidate: string): bool =
  ## A deploy directory is a commit directory holding a `metadata` file.
  fileExists(candidate / "metadata")

proc activeDeployDir(branchDir: string): Option[string] =
  ## Resolve `<branch>/active` to the commit directory it points at.  Falls
  ## back to the most recently modified commit directory that has metadata, so
  ## a partially installed or manually assembled tree still works.
  let activeLink = branchDir / "active"
  if symlinkExists(activeLink):
    var resolved = ""
    try:
      resolved = expandSymlink(activeLink)
    except OSError:
      resolved = ""
    if resolved.len > 0:
      if not isAbsolute(resolved):
        resolved = branchDir / resolved
      if looksLikeDeployDir(resolved):
        return some(resolved)

  var best = ""
  var bestTime = none(Time)
  for commit in sortedSubdirs(branchDir):
    let candidate = branchDir / commit
    if not looksLikeDeployDir(candidate):
      continue
    var stamp: Time
    try:
      stamp = getLastModificationTime(candidate / "metadata")
    except OSError:
      continue
    if bestTime.isNone or stamp > bestTime.get:
      best = candidate
      bestTime = some(stamp)

  if best.len > 0: some(best) else: none(string)

proc metadataCommand*(deployDir: string): string =
  ## The `command=` value from the `[Application]` group of a deploy's
  ## metadata.  Empty when absent -- such refs are skipped, exactly as the
  ## original tool did.
  var text: string
  try:
    text = readFile(deployDir / "metadata")
  except CatchableError:
    return ""
  strip(loadKeyFile(text).getStringOr("Application", "command", ""))

proc metadataAppName*(deployDir: string): string =
  ## Convenience accessor for `[Application] name=`, used only for `--list`.
  var text: string
  try:
    text = readFile(deployDir / "metadata")
  except CatchableError:
    return ""
  strip(loadKeyFile(text).getStringOr("Application", "name", ""))

proc discoverApps*(installation: Installation): seq[AppRef] =
  ## Every installed application ref in `installation` that declares a
  ## command, ordered by id/arch/branch for reproducible output.
  let appRoot = installation.root / "app"
  for id in sortedSubdirs(appRoot):
    for arch in sortedSubdirs(appRoot / id):
      for branch in sortedSubdirs(appRoot / id / arch):
        let branchDir = appRoot / id / arch / branch
        let deploy = activeDeployDir(branchDir)
        if deploy.isNone:
          continue
        let command = metadataCommand(deploy.get)
        if command.len == 0:
          continue
        result.add AppRef(id: id,
                          arch: arch,
                          branch: branch,
                          deployDir: deploy.get,
                          command: command,
                          installation: installation.kind)

proc refName*(appRef: AppRef): string =
  ## The Flatpak "ref" name used on the `flatpak run` command line.
  appRef.id

proc fullyQualified*(appRef: AppRef): string =
  ## `id/arch/branch`, for verbose output.
  appRef.id & "/" & appRef.arch & "/" & appRef.branch

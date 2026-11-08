## Unit tests for the fpcli modules.
##
## Run with:  nim c -r --path:src tests/test_units.nim
## or simply: make test

import std/[options, os, strutils, tempfiles, unittest]

import fpcli/[desktop, flatpak, ini, naming, pathscan, wrapper]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc removeTree(path: string) =
  ## Recursive delete for scratch directories.
  if dirExists(path):
    for kind, sub in walkDir(path):
      if kind == pcDir:
        removeTree(sub)
      else:
        try: removeFile(sub) except OSError: discard
    try: removeDir(path) except OSError: discard

proc makeScratchDir(): string =
  result = createTempDir("fpcli-tests-", "")

proc writeFileCreatingDirs(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc makeApp(root, id, arch, branch, command: string,
             commit = "1a2b3c4d"): string =
  ## Create a plausible `<root>/app/<id>/<arch>/<branch>/...` deploy tree and
  ## return the branch directory.
  let branchDir = root / "app" / id / arch / branch
  writeFileCreatingDirs(branchDir / commit / "metadata",
    "[Application]\n" &
    "name=" & id.split('.')[^1] & "\n" &
    "runtime=runtime/x86_64/stable\n" &
    "sdk=sdk/x86_64/stable\n" &
    "command=" & command & "\n" &
    "\n[Context]\nshared=network;ipc;\n")
  createSymlink(commit, branchDir / "active")
  branchDir

# ---------------------------------------------------------------------------
# ini.nim
# ---------------------------------------------------------------------------

suite "key file parser":
  test "reads groups and keys":
    let kf = loadKeyFile("[Application]\nname=Foo\ncommand=foo %f\n")
    check kf.hasGroup("Application")
    check kf.getString("Application", "name") == some("Foo")
    check kf.getString("Application", "command") == some("foo %f")

  test "ignores comments, blank lines and junk":
    let kf = loadKeyFile("# a comment\n; another\n\nnot a key\n[G]\nk=v\n")
    check kf.hasGroup("G")
    check kf.getString("G", "k") == some("v")

  test "keys outside any group are ignored":
    let kf = loadKeyFile("orphan=1\n[G]\nk=v\n")
    check kf.getString("", "orphan").isNone
    check kf.getString("G", "k") == some("v")

  test "supports backslash line continuations":
    let kf = loadKeyFile("[G]\nk=one\\\n   two\n")
    check kf.getString("G", "k") == some("onetwo")

  test "first occurrence wins":
    let kf = loadKeyFile("[G]\nk=first\nk=second\n")
    check kf.getString("G", "k") == some("first")

  test "missing group or key yields none":
    let kf = loadKeyFile("[G]\nk=v\n")
    check kf.getString("Missing", "k").isNone
    check kf.getString("G", "missing").isNone

  test "localized keys do not shadow the plain key":
    let kf = loadKeyFile("[Desktop Entry]\nName=Plain\nName[de]=Deutsch\n")
    check kf.getString("Desktop Entry", "Name") == some("Plain")

# ---------------------------------------------------------------------------
# desktop.nim
# ---------------------------------------------------------------------------

suite "shell word splitting":
  test "splits on whitespace":
    check shlexSplit("a  b\tc\nd") == @["a", "b", "c", "d"]

  test "honours quoting":
    check shlexSplit("""app "two words" 'three words'""") ==
      @["app", "two words", "three words"]

  test "honours backslash escapes":
    check shlexSplit("""a\ b "c\"d" e""") == @["a b", "c\"d", "e"]

  test "empty and blank input":
    check shlexSplit("").len == 0
    check shlexSplit("   \t ").len == 0

  test "unbalanced quotes are not fatal":
    check shlexSplit("""app "unterminated""") == @["app", "unterminated"]

suite "URL detection in desktop entries":
  test "detects %u and %U":
    check commandlineWantsUrls("app %u")
    check commandlineWantsUrls("app %U")
    check commandlineWantsUrls("app --open %u")

  test "does not treat %f/%F as URLs":
    check not commandlineWantsUrls("app %f")
    check not commandlineWantsUrls("app %F")
    check not commandlineWantsUrls("app")

  test "only whole words count":
    check not commandlineWantsUrls("app --url=%u")

  test "reads Exec from a desktop file":
    let dir = makeScratchDir()
    defer: removeTree(dir)
    let desktopFile = dir / "app.desktop"
    writeFile(desktopFile,
              "[Desktop Entry]\nName=App\nExec=app %u\nType=Application\n")
    check desktopFileWantsUrls(desktopFile)
    check execLine(desktopFile) == some("app %u")

  test "missing or malformed desktop files default to false":
    let dir = makeScratchDir()
    defer: removeTree(dir)
    check not desktopFileWantsUrls(dir / "nope.desktop")
    let broken = dir / "broken.desktop"
    writeFile(broken, "this is not a desktop file\n")
    check not desktopFileWantsUrls(broken)

# ---------------------------------------------------------------------------
# naming.nim
# ---------------------------------------------------------------------------

suite "command name derivation":
  test "strips script extensions":
    check prepareCmdName("86Box.sh", "org.example.Box") == "86box"
    check prepareCmdName("tool.py", "org.example.Tool") == "tool"
    check prepareCmdName("tool.txt", "org.example.Tool") == "tool.txt"

  test "collapses a reverse-DNS command name to its last component":
    check prepareCmdName("com.github.tchx84.Flatseal",
                         "com.github.tchx84.Flatseal") == "flatseal"

  test "only strips reverse DNS when it matches the ref":
    check prepareCmdName("org.other.Thing", "org.example.Thing") == "org.other.thing"

  test "lowercases":
    check prepareCmdName("SweetHome3D", "com.eteks.SweetHome3D") == "sweethome3d"

  test "strips wrapper and launcher suffixes":
    check prepareCmdName("scummvm_wrapper", "org.scummvm.Scummvm") == "scummvm"
    check prepareCmdName("jd-wrapper", "org.example.JD") == "jd"

  test "applies remappings last":
    check prepareCmdName("Play", "org.purei.Play") == "play_emu"
    check prepareCmdName("PPSSPPDL", "org.ppsspp.PPSSPP") == "ppsspp"
    check prepareCmdName("gui-wrapper.sh", "io.github.simple64.simple64") == "simple64"

  test "extra commands are looked up by ref":
    check extraCmdsFor("net.openra.OpenRA") == @["openra-cnc", "openra-d2k"]
    check extraCmdsFor("org.example.None").len == 0

  test "whitespace in metadata is tolerated":
    check prepareCmdName("  Foo  ", "org.example.Foo") == "foo"

suite "command name validation":
  test "accepts ordinary names":
    check validateCommandName("gnome-builder").isNone
    check validateCommandName("86box").isNone
    check validateCommandName("a.b_c+d").isNone

  test "rejects path traversal and separators":
    check validateCommandName("..").isSome
    check validateCommandName(".").isSome
    check validateCommandName("a/b").isSome
    check validateCommandName("/etc/passwd").isSome

  test "rejects unusable names":
    check validateCommandName("").isSome
    check validateCommandName("-rf").isSome
    check validateCommandName("bad\x01name").isSome
    check validateCommandName(repeat('x', 256)).isSome

# ---------------------------------------------------------------------------
# wrapper.nim
# ---------------------------------------------------------------------------

suite "launcher rendering":
  test "renders a path-forwarding launcher":
    let text = renderWrapper("org.example.App", "", wantsUrls = false)
    check text.startsWith("#!/bin/bash\n")
    check text.contains(GeneratedMarker)
    check text.contains("""exec flatpak run --file-forwarding "org.example.App" "${args[@]}"""")
    check text.contains("""args+=("@@")""")
    check not text.contains("@@u")

  test "renders a URL-forwarding launcher":
    let text = renderWrapper("org.example.App", "", wantsUrls = true)
    check text.contains("""args+=("@@u")""")

  test "adds --command for secondary commands":
    let text = renderWrapper("net.openra.OpenRA", "openra-cnc", wantsUrls = false)
    check text.contains("--command=openra-cnc --file-forwarding")
    check text.contains("""for: net.openra.OpenRA --command=openra-cnc""")

  test "cannot be tricked into emitting shell metacharacters":
    let text = renderWrapper("evil\"; rm -rf / #", "", wantsUrls = false)
    # The quote is neutralised, so the ref cannot break out of the quoting.
    check not text.contains("evil\"")
    check text.contains("""exec flatpak run --file-forwarding "evil_; rm -rf / #" "${args[@]}"""")

  test "launcher is written executable and atomically":
    let dir = makeScratchDir()
    defer: removeTree(dir)
    let target = dir / "app"
    check writeLauncher(target, renderWrapper("org.example.App", "", false))
    check fileExists(target)
    check fpUserExec in getFilePermissions(target)
    check fpGroupExec in getFilePermissions(target)
    check fpOthersExec in getFilePermissions(target)
    # No temporary file is left behind.
    var leftovers = 0
    for kind, path in walkDir(dir):
      if kind == pcFile and path.contains(".tmp"):
        inc leftovers
    check leftovers == 0

  test "recognises its own output":
    let dir = makeScratchDir()
    defer: removeTree(dir)
    let target = dir / "app"
    check writeLauncher(target, renderWrapper("org.example.App", "", false))
    check isGeneratedFile(target)

  test "does not claim foreign files":
    let dir = makeScratchDir()
    defer: removeTree(dir)
    let target = dir / "handwritten"
    writeFile(target, "#!/bin/sh\necho mine\n")
    check not isGeneratedFile(target)
    check not removeGenerated(target)
    check fileExists(target)

  test "removes its own output":
    let dir = makeScratchDir()
    defer: removeTree(dir)
    let target = dir / "app"
    check writeLauncher(target, renderWrapper("org.example.App", "", false))
    check removeGenerated(target)
    check not fileExists(target)

# ---------------------------------------------------------------------------
# pathscan.nim
# ---------------------------------------------------------------------------

suite "PATH handling":
  test "splits PATH and drops empty entries":
    check pathDirs("/a:/b::/c/") == @["/a", "/b", "/c"]

  test "finds executables in order":
    let dir = makeScratchDir()
    defer: removeTree(dir)
    createDir(dir / "first")
    createDir(dir / "second")
    writeFile(dir / "second" / "tool", "#!/bin/sh\n")
    setFilePermissions(dir / "second" / "tool", {fpUserRead, fpUserWrite, fpUserExec})
    check findExecutable("tool", @[dir / "first", dir / "second"]) ==
      some(dir / "second" / "tool")
    check findExecutable("tool", @[dir / "first"]).isNone

  test "ignores non-executable files":
    let dir = makeScratchDir()
    defer: removeTree(dir)
    writeFile(dir / "tool", "data\n")
    check findExecutable("tool", @[dir]).isNone

  test "refuses names containing a separator":
    check findExecutable("../bin/sh", @["/bin"]).isNone

  test "detects a missing output directory":
    let report = analyzePath("/nowhere/bin", @["/usr/bin", "/bin"])
    check report.missing
    check report.binDirIndex == -1

  test "detects system directories shadowed by the output directory":
    let report = analyzePath("/home/someone/.local/bin/flatpak",
                             @["/home/someone/.local/bin/flatpak", "/usr/bin", "/bin"])
    check not report.missing
    check report.binDirIndex == 0
    check report.shadowedSystemDirs == @["/usr/bin", "/bin"]

  test "no shadowing when the output directory comes last":
    let report = analyzePath("/home/someone/.local/bin/flatpak",
                             @["/usr/bin", "/bin", "/home/someone/.local/bin/flatpak"])
    check report.binDirIndex == 2
    check report.shadowedSystemDirs.len == 0

# ---------------------------------------------------------------------------
# flatpak.nim
# ---------------------------------------------------------------------------

suite "installation discovery":
  test "finds apps, their command and their arch/branch":
    let root = makeScratchDir()
    defer: removeTree(root)
    discard makeApp(root, "org.example.Foo", "x86_64", "stable", "Foo.sh")
    discard makeApp(root, "org.example.Bar", "x86_64", "beta", "bar")
    let apps = discoverApps(Installation(kind: ikSystem, root: root))
    check apps.len == 2
    check apps[0].id == "org.example.Bar"
    check apps[0].branch == "beta"
    check apps[0].command == "bar"
    check apps[1].id == "org.example.Foo"
    check apps[1].command == "Foo.sh"

  test "skips refs without a command":
    let root = makeScratchDir()
    defer: removeTree(root)
    discard makeApp(root, "org.example.NoCmd", "x86_64", "stable", "")
    check discoverApps(Installation(kind: ikSystem, root: root)).len == 0

  test "falls back to the newest commit when 'active' is missing":
    let root = makeScratchDir()
    defer: removeTree(root)
    let branchDir = makeApp(root, "org.example.Foo", "x86_64", "stable", "foo")
    removeFile(branchDir / "active")
    check discoverApps(Installation(kind: ikSystem, root: root)).len == 1

  test "a missing installation root is not an error":
    check discoverApps(Installation(kind: ikUser, root: "/nonexistent/fpcli")).len == 0

  test "reports refs and app ids":
    let root = makeScratchDir()
    defer: removeTree(root)
    discard makeApp(root, "org.example.Foo", "x86_64", "stable", "foo")
    let appRef = discoverApps(Installation(kind: ikSystem, root: root))[0]
    check appRef.refName == "org.example.Foo"
    check appRef.fullyQualified == "org.example.Foo/x86_64/stable"

  test "honours FLATPAK_*_DIR overrides":
    putEnv("FLATPAK_SYSTEM_DIR", "/tmp/fpcli-sys")
    putEnv("FLATPAK_USER_DIR", "/tmp/fpcli-user")
    defer:
      delEnv("FLATPAK_SYSTEM_DIR")
      delEnv("FLATPAK_USER_DIR")
    check defaultSystemRoot() == "/tmp/fpcli-sys"
    check defaultUserRoot() == "/tmp/fpcli-user"

  test "falls back to XDG_DATA_HOME for the user installation":
    let saved = getEnv("XDG_DATA_HOME")
    putEnv("XDG_DATA_HOME", "/tmp/fpcli-xdg")
    defer:
      if saved.len > 0: putEnv("XDG_DATA_HOME", saved) else: delEnv("XDG_DATA_HOME")
    check defaultUserRoot() == "/tmp/fpcli-xdg/flatpak"

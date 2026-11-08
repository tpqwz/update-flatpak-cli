# Package

version       = "1.0.0"
author        = "Arena Agent"
description   = "Generate traditional CLI launchers for installed Flatpak applications"
license       = "MIT"
srcDir        = "src"
bin           = @["update_flatpak_cli"]
binDir        = "bin"

# Dependencies

requires "nim >= 2.0.0"

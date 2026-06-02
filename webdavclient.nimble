# Package

version       = "0.2.0"
author        = "Beshr Kayali"
description   = "WebDAV Client for Nim"
license       = "MIT"
srcDir        = "src"



# Dependencies

requires "nim >= 2.0.0"
requires "puppy >= 2.0.0"
# Note: on Linux, puppy uses libcurl (install e.g. libcurl4-openssl-dev).
# macOS and Windows use the native HTTP stack and need no extra dependency.


# Tasks

task test, "Run the unit tests (no server required)":
  exec "nim r --hints:off tests/test_parsing.nim"

task integration, "Run the integration tests against a live WebDAV server":
  exec "nim r --hints:off tests/test_webdav.nim"

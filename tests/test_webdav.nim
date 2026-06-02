# Integration test. Requires a live WebDAV server reachable at http://webdav
# with Basic auth admin/password (see tests/docker-compose.test.yml).
# Run with: nimble integration

import webdavclient
import std/[tables, os]

when isMainModule:
  let wd = newWebDAV(
    address = "http://webdav",
    username = "admin",
    password = "password",
  )

  # Make directory
  wd.mkdir(path = "files/")

  # This will fail because directory already exists
  doAssertRaises(OperationFailed):
    wd.mkdir(path = "files/")

  # Upload
  wd.upload(
    filepath = "tests/example.md",
    destination = "files/example.md"
  )

  # File not found (local)
  doAssertRaises(OperationFailed):
    wd.upload(
      filepath = "tests/does_not_exist.md",
      destination = "files/example.md"
    )

  # Re-uploading to an existing path overwrites it and succeeds (valid WebDAV).
  wd.upload(
    filepath = "tests/example.md",
    destination = "files/example.md"
  )

  # Download
  wd.download(
    path = "files/example.md",
    destination = "/tmp/example.md"
  )

  # File exists
  assert fileExists("/tmp/example.md")

  let content = readFile("/tmp/example.md")
  assert content == """# Example

This is an example file.
"""

  # Move
  wd.mv(path = "files/example.md", destination = "example.md")

  # Moving again fails: the source no longer exists
  doAssertRaises(OperationFailed):
    wd.mv(path = "files/example.md", destination = "example.md")

  # Copy
  wd.cp(path = "example.md", destination = "files/example.md")

  # Copying again fails: destination exists and overwrite is off
  doAssertRaises(OperationFailed):
    wd.cp(path = "example.md", destination = "files/example.md")

  # Get possible props
  let props = wd.props("/")

  assert "supportedlock" in props["/"]
  assert "lockdiscovery" in props["/"]
  assert "getcontenttype" in props["/"]

  # List
  let dir1 = wd.ls(
    "/",
    @[
      "getcontentlength",
      "getlastmodified",
      "creationdate",
      "getcontenttype",
    ],
    depth = ONE
  )

  assert dir1.hasKey("/")
  assert dir1.hasKey("/files/")
  assert dir1.hasKey("/example.md")

  # Follow redirects (server redirects /files -> /files/)
  let dir2 = wd.ls(
    "/files",
    depth = ONE
  )

  assert dir2.hasKey("/files/")
  assert dir2.hasKey("/files/example.md")

  # Delete
  wd.rm("example.md")
  wd.rm("files/example.md")
  wd.rm("files/")

  # Does not exist
  doAssertRaises(OperationFailed):
    wd.rm("example.md")

  echo "All integration tests passed."

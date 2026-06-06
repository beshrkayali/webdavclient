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

  # Set a custom property and read it back
  discard wd.proppatch(
    "files/example.md",
    setProps = @[("t:color", "blue")],
    namespaces = @[("t", "http://example.com/ns/")],
  )

  block:
    let afterSet = wd.ls(
      "files/example.md",
      @["t:color"],
      namespaces = @[("t", "http://example.com/ns/")],
      depth = ZERO,
    )
    # The server picks its own prefix, so check the value not the key
    var values: seq[string]
    for _, value in afterSet["/files/example.md"]:
      values.add(value)
    assert "blue" in values

  # Remove the custom property
  discard wd.proppatch(
    "files/example.md",
    removeProps = @["t:color"],
    namespaces = @[("t", "http://example.com/ns/")],
  )

  block:
    let afterRemove = wd.ls(
      "files/example.md",
      @["t:color"],
      namespaces = @[("t", "http://example.com/ns/")],
      depth = ZERO,
    )
    var values: seq[string]
    for _, value in afterRemove["/files/example.md"]:
      values.add(value)
    assert "blue" notin values

  # Setting a read-only property fails
  doAssertRaises(OperationFailed):
    discard wd.proppatch(
      "files/example.md",
      setProps = @[("getcontentlength", "999")],
    )

  # Nothing to set or remove (local)
  doAssertRaises(OperationFailed):
    discard wd.proppatch("files/example.md")

  # Take an exclusive write lock and get a token back
  let lk = wd.lock("files/example.md", owner = "tester")
  assert lk.token.len > 0
  assert lk.scope == EXCLUSIVE

  # Writes without the token are refused while the lock is held
  doAssertRaises(OperationFailed):
    wd.upload(filepath = "tests/example.md", destination = "files/example.md")

  doAssertRaises(OperationFailed):
    wd.rm("files/example.md")

  # The same write succeeds when the token is supplied
  wd.upload(
    filepath = "tests/example.md",
    destination = "files/example.md",
    token = lk.token,
  )

  # Unlocking with a bogus token fails
  doAssertRaises(OperationFailed):
    wd.unlock("files/example.md", "opaquelocktoken:does-not-exist")

  # Release the lock, after which writes need no token again
  wd.unlock("files/example.md", lk.token)
  wd.upload(filepath = "tests/example.md", destination = "files/example.md")

  # Delete
  wd.rm("example.md")
  wd.rm("files/example.md")
  wd.rm("files/")

  # Does not exist
  doAssertRaises(OperationFailed):
    wd.rm("example.md")

  echo "All integration tests passed."

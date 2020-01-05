import webdavclient, asyncdispatch, tables, options, os, streams

when isMainModule:
  let wd = newAsyncWebDAV(
    address = "http://webdav",
    username = "admin",
    password = "password",
  )

  # Make directory
  waitFor wd.mkdir(path = "files/")

  # This will fail because directory already exists
  doAssertRaises(OperationFailed):
    waitFor wd.mkdir(path = "files/")

  # Upload
  waitFor wd.upload(
    filepath = "tests/example.md",
    destination = "files/example.md"
  )

  # File not found
  doAssertRaises(OperationFailed):
    waitFor wd.upload(
      filepath = "tests/does_not_exist.md",
      destination = "files/example.md"
    )

  # File already exists
  doAssertRaises(OperationFailed):
    waitFor wd.upload(
      filepath = "tests/example.md",
      destination = "files/example.md"
    )

  # Download
  waitFor wd.download(
    path = "files/example.md",
    destination = "/tmp/example.md"
  )

  # File exists
  assert fileExists("/tmp/example.md")

  var fs = newFileStream("/tmp/example.md", fmRead)
  let content = fs.readAll()
  assert content == """# Example

This is an example file.
"""

  # Move
  waitFor wd.mv(path = "files/example.md", destination = "example.md")

  # Moving again will fail because it already exists
  doAssertRaises(OperationFailed):
    waitFor wd.mv(path = "files/example.md", destination = "example.md")

  # Copy
  waitFor wd.cp(path = "example.md", destination = "files/example.md")

  # Already exists
  doAssertRaises(OperationFailed):
    waitFor wd.cp(path = "example.md", destination = "files/example.md")

  # Get possible props
  let props = waitFor wd.props(
    "/",
  )

  assert "supportedlock" in props["/"]
  assert "lockdiscovery" in props["/"]
  assert "getcontenttype" in props["/"]

  # List
  let dir1 = waitFor wd.ls(
    "/",
    some(@[
      "getcontentlength",
      "getlastmodified",
      "creationdate",
      "getcontenttype",
    ]),
    depth = ONE
  )

  assert dir1.hasKey("/")
  assert dir1.hasKey("/files/")
  assert dir1.hasKey("/example.md")

  # Follow redirects
  let dir2 = waitFor wd.ls(
    "/files", # server will ask to redirect to /files/
    depth = ONE
  )

  assert dir2.hasKey("/files/")
  assert dir2.hasKey("/files/example.md")

  # Delete
  waitFor wd.rm("example.md")
  waitFor wd.rm("files/example.md")
  waitFor wd.rm("files/")

  # Does not exist
  doAssertRaises(OperationFailed):
    waitFor wd.rm("example.md")

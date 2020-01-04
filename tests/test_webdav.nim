import webdavclient, asyncdispatch, tables, options

when isMainModule:
  let wd = newAsyncWebDAV(
    address = "http://webdav",
    username = "admin",
    password = "password",
    path = ""
  )

  # Make directory
  waitFor wd.mkdir(path = "files/")

  # Upload
  waitFor wd.upload(
    filepath = "tests/example.md",
    destination = "files/example.md"
  )

  # Move
  waitFor wd.mv(path = "files/example.md", destination = "example.md")

  # Copy
  waitFor wd.cp(path = "example.md", destination = "files/example.md")

  # List
  let t = waitFor wd.ls(
    "/",
    some(@[
      "getcontentlength",
      "getlastmodified",
      "creationdate",
      "getcontenttype",
    ]),
    depth = ONE
  )

  assert t.hasKey("/")
  assert t.hasKey("/files/")
  assert t.hasKey("/example.md")

  # Delete
  waitFor wd.rm("example.md")
  waitFor wd.rm("files/example.md")
  waitFor wd.rm("files/")

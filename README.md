### WebDAV Client for Nim

This is an implementation for some of the basic
operations to communicate with a WebDAV server using Nim.


Example usage:

```
import webdavclient, asyncdispatch

let wd = newAsyncWebDAV(
  address="https://wd.example.com",
  username="",
  password="",
  path="/remote.php/dav/"
)

# List files
let t = waitFor wd.ls(
  "files/",
  props=@["d:getlastmodified", "d:getetag", "d:getcontenttype", "d:resourcetype", "d:getcontentlength"],
  namespaces={"xmlns:oc": "http://owncloud.org/ns"}.newStringTable,
  depth=2
)

for url, props in t.pairs:
  echo(url)
  echo(prop)
  echo("---")


# Downlaod a file
waitFor wd.download("files/example.md", "/home/me/example.md")

# Upload a file
waitFor wd.upload("files/example.md", "/home/me/example.md")

# Delete a file
waitFor wd.rm("files/example.md")

# Create a collection (directory)
waitFor wd.mkdir("files/new/")

# Move a file
waitFor wd.mv("files/example.md", "files/new/example.md")

# Copy a file
waitFor wd.cp("files/new/example.md", "files/example.md")
```

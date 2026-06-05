### WebDAV Client for Nim

[![](https://github.com/beshrkayali/webdavclient/workflows/CI/badge.svg)](https://github.com/beshrkayali/webdavclient/actions?query=workflow%3ACI)


This is an implementation for some of the basic
operations to communicate with a WebDAV server using Nim.

The client is **synchronous** and is built on top of
[puppy](https://github.com/treeform/puppy). On Linux puppy uses libcurl, so
install it (e.g. `libcurl4-openssl-dev`) to build; macOS and Windows use the
native HTTP stack and need no extra dependency.


Example usage:

```nim
import webdavclient, tables

# Only Basic auth is currently supported. Make sure you're
# connecting over ssl.

let wd = newWebDAV(
  address = "https://dav.example.com",
  username = "username",
  password = "password"
)

# Get the property names available for a resource (propname request)
let possibleProps = wd.props("/", depth = ZERO)

for href, names in possibleProps:
  echo href, ": ", names

# List files.
# Default webdav properties don't require a namespace.
let t = wd.ls(
  "/",
  @[
    "getcontentlength",
    "getlastmodified",
    "creationdate",
    "getcontenttype",
    "nc:has-preview",
    "oc:favorite",
  ],
  namespaces = @[
    ("oc", "http://owncloud.org/ns"),
    ("nc", "http://nextcloud.org/ns")
  ],
  depth = ONE
)

for url, prop in t.pairs:
  echo(url)
  for pname, pval in prop.pairs:
    echo(" - ", pname, ": ", pval)
  echo("---")

# Download a file (buffered in memory, then written to disk)
wd.download(path = "files/example.md", destination = "/home/me/example.md")

# Upload a file
wd.upload(filepath = "files/example.md", destination = "/home/me/example.md")

# Delete a file
wd.rm("files/example.md")

# Create a collection (directory)
wd.mkdir("files/new/")

# Move a file
wd.mv(path = "files/example.md", destination = "files/new/example.md", overwrite = true)

# Copy a file
wd.cp(path = "files/new/example.md", destination = "files/example.md", overwrite = true)

# Set and/or remove properties (PROPPATCH)
discard wd.proppatch(
  "files/example.md",
  setProps = @[("oc:favorite", "1")],
  removeProps = @["oc:tag"],
  namespaces = @[("oc", "http://owncloud.org/ns")]
)
```

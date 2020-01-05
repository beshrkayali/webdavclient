### WebDAV Client for Nim

[![](https://github.com/beshrkayali/webdavclient/workflows/CI/badge.svg)](https://github.com/beshrkayali/webdavclient/actions?query=workflow%3ACI)


This is an implementation for some of the basic
operations to communicate with a WebDAV server using Nim.


Example usage:

```nim
import webdavclient, asyncdispatch, tables, options

# Only Basic auth is currently supported. Make sure you're
# connecting over ssl

let wd = newAsyncWebDAV(
  address="https://dav.example.com",
  username="username",
  password="password"
)

# Get props (propname request)
let possible_props = waitFor wd.props(
  "/",
  depth=ZERO
)

for url, props in possible_props["/"]:
  echo(url, props)

# List files
# Default webdav properties don't require a namespace
let t = waitFor wd.ls(
  "/",
  props=some(@[
    "getcontentlength",
    "getlastmodified",
	"creationdate",
	"getcontenttype",
	"nc:has-preview",
	"oc:favorite",
  ]),
  namespaces=some(@[
    ("oc", "http://owncloud.org/ns"),
    ("nc", "http://nextcloud.org/ns")
  ]),
  depth=ONE
)

for url, prop in t.pairs:
  echo(url)
  for pname, pval in v.pairs:
    echo(" - " , pname, ": ", pval)
  echo("---")

# Downlaod a file
waitFor wd.download(path="files/example.md", destination="/home/me/example.md")

# Upload a file
waitFor wd.upload(filepath="files/example.md", destination="/home/me/example.md")

# Delete a file
waitFor wd.rm("files/example.md")

# Create a collection (directory)
waitFor wd.mkdir("files/new/")

# Move a file
waitFor wd.mv(path="files/example.md", destination="files/new/example.md", overwrite=true)

# Copy a file
waitFor wd.cp(path="files/new/example.md", destination="files/example.md", overwrite=true)
```

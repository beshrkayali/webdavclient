# Unit tests for the pure XML parsing helpers. These need no WebDAV server.
# We `include` the module so we can reach its (private) parse procs.

import std/[unittest, tables]

include "../src/webdavclient.nim"

const propfindListBody = """<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/files/</D:href>
    <D:propstat>
      <D:prop>
        <D:getlastmodified>Mon, 01 Jan 2024 00:00:00 GMT</D:getlastmodified>
        <D:resourcetype><D:collection/></D:resourcetype>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/files/example.md</D:href>
    <D:propstat>
      <D:prop>
        <D:getcontentlength>34</D:getcontentlength>
        <D:getcontenttype>text/markdown</D:getcontenttype>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>"""

const propNamesBody = """<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype/>
        <d:getcontenttype/>
        <d:supportedlock/>
        <d:lockdiscovery/>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>"""

const proppatchSuccessBody = """<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:Z="http://ns.example.com/z/">
  <D:response>
    <D:href>/files/example.md</D:href>
    <D:propstat>
      <D:prop>
        <Z:Author/>
        <Z:Title/>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>"""

const proppatchMixedBody = """<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:" xmlns:Z="http://ns.example.com/z/">
  <D:response>
    <D:href>/bar.html</D:href>
    <D:propstat>
      <D:prop><Z:Authors/></D:prop>
      <D:status>HTTP/1.1 424 Failed Dependency</D:status>
    </D:propstat>
    <D:propstat>
      <D:prop><Z:Copyright-Owner/></D:prop>
      <D:status>HTTP/1.1 409 Conflict</D:status>
    </D:propstat>
    <D:responsedescription>Copyright Owner cannot be deleted or altered.</D:responsedescription>
  </D:response>
</D:multistatus>"""

suite "parsePropfindList":
  test "extracts hrefs and their properties":
    let files = parsePropfindList(propfindListBody, "")
    check files.len == 2
    check files.hasKey("/files/")
    check files.hasKey("/files/example.md")
    check files["/files/example.md"]["D:getcontentlength"] == "34"
    check files["/files/example.md"]["D:getcontenttype"] == "text/markdown"
    check files["/files/"]["D:resourcetype"] == ""

  test "strips the given prefix from hrefs":
    let files = parsePropfindList(propfindListBody, "/files")
    check files.hasKey("/")
    check files.hasKey("/example.md")
    check not files.hasKey("/files/")

  test "handles a response with no propstat":
    const body = """<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/lonely.txt</D:href></D:response>
</D:multistatus>"""
    let files = parsePropfindList(body, "")
    check files.hasKey("/lonely.txt")
    check files["/lonely.txt"].len == 0

suite "parsePropNames":
  test "collects property names with the namespace prefix stripped":
    let props = parsePropNames(propNamesBody)
    check props.hasKey("/")
    check "supportedlock" in props["/"]
    check "lockdiscovery" in props["/"]
    check "getcontenttype" in props["/"]
    check "resourcetype" in props["/"]
    check props["/"].len == 4

suite "parseProppatchResponse":
  test "maps property names to their status code":
    let res = parseProppatchResponse(proppatchSuccessBody)
    check res.len == 2
    check res["Z:Author"] == 200
    check res["Z:Title"] == 200

  test "groups properties by status across multiple propstats":
    let res = parseProppatchResponse(proppatchMixedBody)
    check res.len == 2
    check res["Z:Authors"] == 424
    check res["Z:Copyright-Owner"] == 409

suite "statusCode":
  test "extracts the numeric code from a status line":
    check statusCode("HTTP/1.1 200 OK") == 200
    check statusCode("HTTP/1.1 424 Failed Dependency") == 424
    check statusCode("garbage") == 0

suite "is2xx":
  test "classifies status codes":
    check is2xx(200)
    check is2xx(204)
    check is2xx(299)
    check not is2xx(199)
    check not is2xx(300)
    check not is2xx(404)

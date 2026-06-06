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

const lockBody = """<?xml version="1.0" encoding="utf-8"?>
<D:prop xmlns:D="DAV:">
  <D:lockdiscovery>
    <D:activelock>
      <D:locktype><D:write/></D:locktype>
      <D:lockscope><D:exclusive/></D:lockscope>
      <D:depth>infinity</D:depth>
      <D:owner>tester</D:owner>
      <D:timeout>Second-3600</D:timeout>
      <D:locktoken>
        <D:href>opaquelocktoken:8db16e4f-9f10-4487-af81-cdf77d3b3745</D:href>
      </D:locktoken>
      <D:lockroot>
        <D:href>http://webdav/files/example.md</D:href>
      </D:lockroot>
    </D:activelock>
  </D:lockdiscovery>
</D:prop>"""

const sharedLockBody = """<?xml version="1.0"?>
<D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>
  <D:lockscope><D:shared/></D:lockscope>
  <D:locktype><D:write/></D:locktype>
  <D:depth>0</D:depth>
  <D:locktoken><D:href>opaquelocktoken:abc</D:href></D:locktoken>
</D:activelock></D:lockdiscovery></D:prop>"""

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

suite "parseLockResponse":
  test "extracts the lock token and metadata":
    let lk = parseLockResponse(lockBody)
    check lk.token == "opaquelocktoken:8db16e4f-9f10-4487-af81-cdf77d3b3745"
    check lk.scope == EXCLUSIVE
    check lk.depth == INF
    check lk.owner == "tester"
    check lk.timeout == "Second-3600"
    check lk.root == "http://webdav/files/example.md"

  test "handles a shared lock with depth zero":
    let lk = parseLockResponse(sharedLockBody)
    check lk.token == "opaquelocktoken:abc"
    check lk.scope == SHARED
    check lk.depth == ZERO

suite "ifHeaders":
  test "builds an If header only when a token is given":
    check ifHeaders("").len == 0
    check ifHeaders("opaquelocktoken:abc") ==
      @[("If", "(<opaquelocktoken:abc>)")]

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

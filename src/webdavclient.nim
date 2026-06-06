## A WebDAV Client for Nim.
##
## Built on top of `puppy <https://github.com/treeform/puppy>`_, so the API is
## synchronous. On Linux puppy needs libcurl available at build/run time;
## macOS and Windows use the native HTTP stack.

import std/[base64, strutils, tables, strtabs, xmlparser, xmltree, os, uri]
import puppy

type
  OperationFailed* = object of CatchableError
    ## Raised when the server (or a local check) reports a failed operation.
    ## `code` carries the HTTP status code (0 for local failures).
    code*: int

  FilesTable* = Table[string, string]

  Namespace* = tuple
    name: string
    url: string

  Depth* = enum
    ZERO = "0"
    ONE = "1"
    INF = "infinity"

  LockScope* = enum
    EXCLUSIVE = "exclusive"
    SHARED = "shared"

  Lock* = object
    ## A write lock returned by `lock`. `token` identifies the lock and must
    ## be passed to `unlock` and to any write touching the locked resource.
    token*: string
    root*: string
    scope*: LockScope
    depth*: Depth
    owner*: string
    timeout*: string

  WebDAV* = ref object
    address*: string
    path*: string
    timeout*: float32
    username: string
    password: string


proc operationFailed(msg: string, code: int) {.noreturn.} =
  ## Raise an `OperationFailed` carrying the HTTP status `code`.
  var e = newException(OperationFailed, msg)
  e.code = code
  raise e


proc operationFailed(msg: string) {.noreturn.} =
  raise newException(OperationFailed, msg)


proc is2xx(code: int): bool =
  code >= 200 and code < 300


proc ifHeaders(token: string): seq[(string, string)] =
  ## Build the `If` header that submits a lock `token` on a write request
  ## (RFC 4918, section 10.4). Empty when no token is given.
  if token.len > 0:
    @[("If", "(<" & token & ">)")]
  else:
    @[]


proc statusCode(statusLine: string): int =
  ## Pull the numeric code out of a status line like "HTTP/1.1 200 OK".
  let parts = statusLine.splitWhitespace()
  if parts.len >= 2:
    try:
      result = parseInt(parts[1])
    except ValueError:
      result = 0


proc newWebDAV*(
  address: string,
  username: string,
  password: string,
  path: string = "",
  timeout: float32 = 60,
): WebDAV =
  ## Create a webdav client. Only Basic auth is supported for now.
  WebDAV(
    path: path,
    address: $(parseUri(address) / path),
    username: username,
    password: password,
    timeout: timeout,
  )


proc request(
  wd: WebDAV,
  path: string,
  verb: string,
  body: string = "",
  extraHeaders: seq[(string, string)] = @[],
): Response =
  ## Issue a request to `path` (joined onto the client address) with Basic auth.
  ## puppy follows redirects and keeps the custom verb across them.
  var headers: HttpHeaders
  headers["Authorization"] = "Basic " & base64.encode(wd.username & ":" & wd.password)
  for (k, v) in extraHeaders:
    headers[k] = v
  if body.len > 0 and "Content-Type" notin headers:
    headers["Content-Type"] = "application/xml; charset=utf-8"

  let req = newRequest(
    $(parseUri(wd.address) / path),
    verb = verb,
    headers = headers,
    timeout = wd.timeout,
  )
  req.body = body
  result = fetch(req)


proc getDefaultXmlAttrs(): XmlAttributes =
  {"xmlns": "DAV:"}.toXmlAttributes


proc parsePropfindList(
  body: string, stripPrefix: string
): Table[string, FilesTable] =
  ## Parse a PROPFIND multistatus response into a table of (relative href ->
  ## its properties). `stripPrefix` is removed from the start of each href.
  let node = parseXml(body)
  let ns = node.tag.split(":")[0] & ":"
  result = initTable[string, FilesTable]()

  for item in node:
    let href = item.child(ns & "href")
    if href == nil:
      continue

    var propsTable: FilesTable
    let propstat = item.child(ns & "propstat")
    if propstat != nil:
      for prop in propstat.findAll(ns & "prop"):
        for p in prop:
          propsTable[p.tag] = p.innerText

    var key = href.innerText
    if stripPrefix.len > 0:
      key = key.replace(stripPrefix, "")
    result[key] = propsTable


proc parsePropNames(body: string): Table[string, seq[string]] =
  ## Parse a `propname` PROPFIND response into a table of (href -> property
  ## names available for that resource).
  let node = parseXml(body)
  let ns = node.tag.split(":")[0] & ":"
  result = initTable[string, seq[string]]()

  for response in node.findAll(ns & "response"):
    let href = response.child(ns & "href")
    if href == nil:
      continue

    var names: seq[string]
    for propstat in response.findAll(ns & "propstat"):
      for prop in propstat.findAll(ns & "prop"):
        for p in prop:
          names.add(p.tag.replace(ns, ""))
    result[href.innerText] = names


proc parseProppatchResponse(body: string): Table[string, int] =
  ## Parse a PROPPATCH multistatus response into a table of (property name
  ## -> HTTP status code). Properties are grouped by status across several
  ## `propstat` elements.
  let node = parseXml(body)
  let ns = node.tag.split(":")[0] & ":"
  result = initTable[string, int]()

  let response = node.child(ns & "response")
  if response == nil:
    return

  for propstat in response.findAll(ns & "propstat"):
    let status = propstat.child(ns & "status")
    if status == nil:
      continue
    let code = statusCode(status.innerText)
    for prop in propstat.findAll(ns & "prop"):
      for p in prop:
        result[p.tag] = code


proc parseLockResponse(body: string): Lock =
  ## Parse the prop/lockdiscovery/activelock body returned by a LOCK request.
  ## The `Lock-Token` response header carries the authoritative token, so
  ## callers usually overwrite `token` with it afterwards.
  result = Lock(scope: EXCLUSIVE, depth: INF)
  let node = parseXml(body)
  let ns = node.tag.split(":")[0] & ":"

  let lockdiscovery = node.child(ns & "lockdiscovery")
  if lockdiscovery == nil:
    return
  let activelock = lockdiscovery.child(ns & "activelock")
  if activelock == nil:
    return

  let locktoken = activelock.child(ns & "locktoken")
  if locktoken != nil:
    let href = locktoken.child(ns & "href")
    if href != nil:
      result.token = href.innerText.strip()

  let lockroot = activelock.child(ns & "lockroot")
  if lockroot != nil:
    let href = lockroot.child(ns & "href")
    if href != nil:
      result.root = href.innerText.strip()

  let lockscope = activelock.child(ns & "lockscope")
  if lockscope != nil and lockscope.child(ns & "shared") != nil:
    result.scope = SHARED

  let depth = activelock.child(ns & "depth")
  if depth != nil and depth.innerText.strip() == "0":
    result.depth = ZERO

  let owner = activelock.child(ns & "owner")
  if owner != nil:
    result.owner = owner.innerText.strip()

  let timeout = activelock.child(ns & "timeout")
  if timeout != nil:
    result.timeout = timeout.innerText.strip()


proc ls*(
  wd: WebDAV,
  path: string,
  props: seq[string] = @[],
  namespaces: seq[Namespace] = @[],
  depth: Depth = ONE,
): Table[string, FilesTable] =
  ## Returns a table of relative urls (of files and directories)
  ## and their properties at specified path (or only of the specified
  ## path if `depth` is set to `ZERO`).
  ##
  ## `DAV:` is the default namespace, meaning dav properties
  ## can be provided directly without a namespace.
  ## For example:
  ##
  ## ```nim
  ## wd.ls(
  ##   "/",
  ##   @["getcontentlength", "getlastmodified"],
  ##   depth = ONE
  ## )
  ## ```
  ##
  ## If no props are provided, no request body will be sent.
  var reqBody = ""

  if props.len > 0:
    var nsAttrs = getDefaultXmlAttrs()
    for (ns, url) in namespaces:
      nsAttrs["xmlns:" & ns] = url

    var propNode = newElement("prop")
    for p in props:
      propNode.add(newElement(p))

    var reqXml = newElement("propfind")
    reqXml.attrs = nsAttrs
    reqXml.add(propNode)

    reqBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" & $reqXml

  let resp = wd.request(
    path,
    verb = "PROPFIND",
    body = reqBody,
    extraHeaders = @[("Depth", $depth)],
  )

  if resp.code != 207:
    operationFailed(
      "Got unexpected status " & $resp.code &
        " with response from server:\n" & resp.body,
      resp.code,
    )

  result = parsePropfindList(resp.body, wd.path)


proc props*(
  wd: WebDAV,
  path: string,
  namespaces: seq[Namespace] = @[],
  depth: Depth = ONE,
): Table[string, seq[string]] =
  ## Returns the property names available for each resource at `path`
  ## (a `propname` PROPFIND request).
  var nsAttrs = getDefaultXmlAttrs()
  for (ns, url) in namespaces:
    nsAttrs["xmlns:" & ns] = url

  var reqXml = newElement("propfind")
  reqXml.attrs = nsAttrs
  reqXml.add(newElement("propname"))

  let reqBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" & $reqXml

  let resp = wd.request(
    path,
    verb = "PROPFIND",
    body = reqBody,
    extraHeaders = @[("Depth", $depth)],
  )

  if resp.code != 207:
    operationFailed(
      "Got unexpected response from server:\n" & resp.body, resp.code
    )

  result = parsePropNames(resp.body)


proc proppatch*(
  wd: WebDAV,
  path: string,
  setProps: seq[(string, string)] = @[],
  removeProps: seq[string] = @[],
  namespaces: seq[Namespace] = @[],
  token: string = "",
): Table[string, int] =
  ## Set and/or remove properties on the resource at `path`. `setProps` is
  ## a list of (name, value) pairs to set; `removeProps` is a list of names
  ## to remove. Setting happens before removing.
  ##
  ## Property names can carry a namespace prefix declared in `namespaces`,
  ## the same as with `ls`. `DAV:` is the default namespace.
  ##
  ## ```nim
  ## discard wd.proppatch(
  ##   "/files/example.md",
  ##   setProps = @[("oc:favorite", "1")],
  ##   removeProps = @["oc:tag"],
  ##   namespaces = @[("oc", "http://owncloud.org/ns")],
  ## )
  ## ```
  ##
  ## Returns a table of property names to status codes. PROPPATCH is atomic,
  ## so any property with a non-2xx status raises `OperationFailed`.
  if setProps.len == 0 and removeProps.len == 0:
    operationFailed("proppatch requires at least one property to set or remove")

  var nsAttrs = getDefaultXmlAttrs()
  for (ns, url) in namespaces:
    nsAttrs["xmlns:" & ns] = url

  var reqXml = newElement("propertyupdate")
  reqXml.attrs = nsAttrs

  if setProps.len > 0:
    var propNode = newElement("prop")
    for (name, value) in setProps:
      var el = newElement(name)
      el.add(newText(value))
      propNode.add(el)
    var setNode = newElement("set")
    setNode.add(propNode)
    reqXml.add(setNode)

  if removeProps.len > 0:
    var propNode = newElement("prop")
    for name in removeProps:
      propNode.add(newElement(name))
    var removeNode = newElement("remove")
    removeNode.add(propNode)
    reqXml.add(removeNode)

  let reqBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" & $reqXml

  let resp = wd.request(
    path,
    verb = "PROPPATCH",
    body = reqBody,
    extraHeaders = ifHeaders(token),
  )

  if resp.code != 207:
    operationFailed(
      "Got unexpected status " & $resp.code &
        " with response from server:\n" & resp.body,
      resp.code,
    )

  result = parseProppatchResponse(resp.body)

  for name, code in result:
    if not is2xx(code):
      operationFailed(
        "Property \"" & name & "\" failed with status " & $code & ":\n" &
          resp.body,
        code,
      )


proc lock*(
  wd: WebDAV,
  path: string,
  scope: LockScope = EXCLUSIVE,
  owner: string = "",
  depth: Depth = INF,
  timeout: string = "",
): Lock =
  ## Take a write lock on the resource at `path` (RFC 4918, section 9.10) and
  ## return the resulting `Lock`. Its `token` must be passed to `unlock` and
  ## to any write touching the locked resource (the `token` parameter on
  ## `upload`, `mkdir`, `rm`, `mv`, `cp`, and `proppatch`).
  ##
  ## `depth` must be `ZERO` or `INF`. `timeout` is an optional hint such as
  ## "Second-3600" or "Infinite"; the server may choose its own.
  var lockInfo = newElement("lockinfo")
  lockInfo.attrs = getDefaultXmlAttrs()

  var scopeNode = newElement("lockscope")
  scopeNode.add(newElement($scope))
  lockInfo.add(scopeNode)

  var typeNode = newElement("locktype")
  typeNode.add(newElement("write"))
  lockInfo.add(typeNode)

  if owner.len > 0:
    var ownerNode = newElement("owner")
    ownerNode.add(newText(owner))
    lockInfo.add(ownerNode)

  let reqBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" & $lockInfo

  var extra = @[("Depth", $depth)]
  if timeout.len > 0:
    extra.add(("Timeout", timeout))

  let resp = wd.request(path, verb = "LOCK", body = reqBody, extraHeaders = extra)

  if resp.code notin [200, 201]:
    operationFailed(resp.body, resp.code)

  result = parseLockResponse(resp.body)
  let header = resp.headers["Lock-Token"]
  if header.len > 0:
    result.token = header.strip(chars = {'<', '>'})


proc unlock*(
  wd: WebDAV,
  path: string,
  token: string,
) =
  ## Release the lock identified by `token` on `path` (section 9.11).
  let resp = wd.request(
    path,
    verb = "UNLOCK",
    extraHeaders = @[("Lock-Token", "<" & token & ">")],
  )

  if resp.code != 204:
    operationFailed(resp.body, resp.code)


proc download*(
  wd: WebDAV,
  path: string,
  destination: string,
) =
  ## Download the resource at `path` to a local file. The whole body is
  ## buffered in memory before being written.
  let resp = wd.request(path, verb = "GET")

  if resp.code != 200:
    operationFailed(resp.body, resp.code)

  writeFile(destination, resp.body)


proc upload*(
  wd: WebDAV,
  filepath: string,
  destination: string,
  token: string = "",
) =
  ## Upload a local file to `destination`. Pass `token` to write through a
  ## lock held on the destination.
  if not fileExists(filepath):
    operationFailed("File \"" & filepath & "\" not found")

  let resp = wd.request(
    destination,
    verb = "PUT",
    body = readFile(filepath),
    extraHeaders = ifHeaders(token),
  )

  if not is2xx(resp.code):
    operationFailed(resp.body, resp.code)


proc mkdir*(
  wd: WebDAV,
  path: string,
  token: string = "",
) =
  ## Create a collection (directory). Pass `token` to write through a lock
  ## held on the parent collection.
  let resp = wd.request(path, verb = "MKCOL", extraHeaders = ifHeaders(token))

  if resp.code notin [200, 201]:
    operationFailed(resp.body, resp.code)


proc rm*(
  wd: WebDAV,
  path: string,
  token: string = "",
) =
  ## Delete a file or directory. If path is a directory,
  ## all resources within will be deleted recursively.
  ## Pass `token` to write through a lock held on the target.
  let resp = wd.request(path, verb = "DELETE", extraHeaders = ifHeaders(token))

  if resp.code notin [200, 204]:
    operationFailed(resp.body, resp.code)


proc mv*(
  wd: WebDAV,
  path: string,
  destination: string,
  overwrite: bool = false,
  depth: Depth = INF,
  token: string = "",
) =
  ## Move a resource from one location to another. Pass `token` to write
  ## through a lock held on the source or destination.
  let resp = wd.request(
    path,
    verb = "MOVE",
    extraHeaders = @[
      ("Destination", $(parseUri(wd.address) / destination)),
      ("Overwrite", if overwrite: "T" else: "F"),
      ("Depth", $depth),
    ] & ifHeaders(token),
  )

  if resp.code notin [201, 204]:
    operationFailed(resp.body, resp.code)


proc cp*(
  wd: WebDAV,
  path: string,
  destination: string,
  overwrite: bool = false,
  depth: Depth = INF,
  token: string = "",
) =
  ## Copy a resource to another location. Pass `token` to write through a
  ## lock held on the destination.
  let resp = wd.request(
    path,
    verb = "COPY",
    extraHeaders = @[
      ("Destination", $(parseUri(wd.address) / destination)),
      ("Overwrite", if overwrite: "T" else: "F"),
      ("Depth", $depth),
    ] & ifHeaders(token),
  )

  if resp.code notin [201, 204]:
    operationFailed(resp.body, resp.code)

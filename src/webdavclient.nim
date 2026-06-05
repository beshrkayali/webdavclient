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

  let resp = wd.request(path, verb = "PROPPATCH", body = reqBody)

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
) =
  ## Upload a local file to `destination`.
  if not fileExists(filepath):
    operationFailed("File \"" & filepath & "\" not found")

  let resp = wd.request(destination, verb = "PUT", body = readFile(filepath))

  if not is2xx(resp.code):
    operationFailed(resp.body, resp.code)


proc mkdir*(
  wd: WebDAV,
  path: string,
) =
  ## Create a collection (directory).
  let resp = wd.request(path, verb = "MKCOL")

  if resp.code notin [200, 201]:
    operationFailed(resp.body, resp.code)


proc rm*(
  wd: WebDAV,
  path: string,
) =
  ## Delete a file or directory. If path is a directory,
  ## all resources within will be deleted recursively.
  let resp = wd.request(path, verb = "DELETE")

  if resp.code notin [200, 204]:
    operationFailed(resp.body, resp.code)


proc mv*(
  wd: WebDAV,
  path: string,
  destination: string,
  overwrite: bool = false,
  depth: Depth = INF,
) =
  ## Move a resource from one location to another.
  let resp = wd.request(
    path,
    verb = "MOVE",
    extraHeaders = @[
      ("Destination", $(parseUri(wd.address) / destination)),
      ("Overwrite", if overwrite: "T" else: "F"),
      ("Depth", $depth),
    ],
  )

  if resp.code notin [201, 204]:
    operationFailed(resp.body, resp.code)


proc cp*(
  wd: WebDAV,
  path: string,
  destination: string,
  overwrite: bool = false,
  depth: Depth = INF,
) =
  ## Copy a resource to another location.
  let resp = wd.request(
    path,
    verb = "COPY",
    extraHeaders = @[
      ("Destination", $(parseUri(wd.address) / destination)),
      ("Overwrite", if overwrite: "T" else: "F"),
      ("Depth", $depth),
    ],
  )

  if resp.code notin [201, 204]:
    operationFailed(resp.body, resp.code)

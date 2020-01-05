## A WebDAV Client for Nim.

import options
from sequtils import zip
from strutils import replace, split, parseInt
import strtabs, tables, base64, xmlparser, xmltree, streams
import uri, asyncdispatch, httpClient


type
  OperationFailed* = object of Exception
    code: HttpCode

type
  filesTable = Table[string, string]
  header = tuple
    name: string
    value: string
  namespace = tuple
    name: string
    url: string

type
  Depth* = enum
    ZERO = "0"
    ONE = "1"
    INF = "infinity"


proc operationFailed(msg: string, code: HttpCode) {.noreturn.} =
  ## raises an OperationFailed exception with message `msg`.
  var e: ref OperationFailed
  new(e)
  e.msg = msg
  e.code = code
  raise e


proc operationFailed(msg: string) {.noreturn.} =
  var e: ref OperationFailed
  new(e)
  e.msg = msg
  raise e


type AsyncWebDAV* = ref object of RootObj
  client*: AsyncHttpClient
  path*: string
  address*: string
  username: string
  password: string


proc newAsyncWebDAV*(
  address: string,
  username: string,
  password: string,
  path: string = ""
): AsyncWebDAV =
  ## Create an async webdav client. Only Basic auth is supported for now.
  let fulladdr = parseUri(address) / path
  let client = newAsyncHttpClient()

  AsyncWebDAV(
    client: client,
    path: path,
    address: $fulladdr,
    username: username,
    password: password,
  )


proc request(
  wd: AsyncWebDAV,
  path: string,
  httpMethod: string,
  body: string = "",
  headers: Option[seq[header]] = none(seq[header]),
): Future[AsyncResponse] {.async.} =

  let auth = "Basic " & base64.encode(
    wd.username & ":" & wd.password
  )

  wd.client.headers = newHttpHeaders({"Authorization": auth})

  if isSome(headers):
    for (h, v) in headers.get:
      wd.client.headers[h] = v

  return await wd.client.request(
    $(parseUri(wd.address) / path),
    httpMethod = httpMethod,
    body = body
  )


proc getDefaultXmlAttrs(): XmlAttributes =
  {"xmlns": "DAV:"}.toXmlAttributes


proc ls*(
  wd: AsyncWebDAV,
  path: string,
  props: Option[seq[string]] = none(seq[string]),
  namespaces: Option[seq[namespace]] = none(seq[namespace]),
  depth: Depth = ONE,
): Future[Table[string, filesTable]] {.async.} =
  ## Returns a table of relative urls (of files and directories)
  ## and their properties at specified path (or only of the specified
  ## path if `depth` is set to `ZERO`.
  ##
  ## `DAV:` is the default namespace, meaning dav properties
  ## can be provided directly without a namespace.
  ## For example:
  ##
  ## ```nim
  ## wd.ls(
  ##   "/",
  ##   some(@["getcontentlength", "getlastmodified"]),
  ##   depth=ONE
  ## )
  ## ```
  ##
  ## If no props are provided, no request body will be sent.

  var propNode = newElement("prop")
  var nsAttrs = getDefaultXmlAttrs()

  if isSome(namespaces):
    for (ns, url) in namespaces.get:
      nsAttrs["xmlns:" & ns] = url

  var reqBody = ""

  if isSome(props):
    for p in props.get:
      let pNode = newElement(p)
      propNode.add(pNode)

    var reqXml = newElement("propfind")
    reqXml.attrs = nsAttrs
    reqXml.add(propNode)

    reqBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" & $reqXml

  let resp = await wd.request(
    path,
    httpMethod = "PROPFIND",
    body = reqBody,
    headers = some(@[("Depth", $depth)])
  )

  if resp.code != HttpCode(207):
    operationFailed(
      "Got unexpected response from server:\n" & await resp.body, resp.code
    )

  let body = await resp.body
  let node: XmlNode = parseXml(body)
  var files = initTable[string, filesTable]()
  var hrefs = newSeq[string]()
  var propsTables = newSeq[filesTable]()

  let NS = node.tag.split(":")[0] & ":"

  for item in node:
    let href = item.child(NS & "href")
    let props = item.child(NS & "propstat")
    hrefs.add(href.innerText.replace(wd.path, ""))

    var propsTable: filesTable
    for prop in props.findAll(NS & "prop"):
      for p in prop:
        propsTable[p.tag] = p.innerText

    propsTables.add(propsTable)

  for pairs in zip(hrefs, propsTables):
    let (href, props) = pairs
    files[href] = props

  return files

proc props*(
  wd: AsyncWebDAV,
  path: string,
  namespaces: Option[seq[namespace]] = none(seq[namespace]),
  depth: Depth = ONE,
): Future[Table[string, seq[string]]] {.async.} =
  var reqXml = newElement("propfind")

  var nsAttrs = getDefaultXmlAttrs()

  if isSome(namespaces):
    for (ns, url) in namespaces.get:
      nsAttrs["xmlns:" & ns] = url

  reqXml.attrs = nsAttrs
  reqXml.add(newElement("propname"))

  let reqBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" & $reqXml

  let resp = await wd.request(
    path,
    httpMethod = "PROPFIND",
    body = reqBody,
    headers = some(
      @[("Depth", $depth)]
    )
  )

  if resp.code != HttpCode(207):
    operationFailed(
      "Got unexpected response from server:\n" & await resp.body, resp.code
    )

  let body = await resp.body
  let node: XmlNode = parseXml(body)

  var properties = initTable[string, seq[string]]()

  let NS = node.tag.split(":")[0] & ":"

  for response in node.findAll(NS & "response"):
    let href = response.child(NS & "href")
    properties[href.innerText] = @[]
    let props = response.child(NS & "propstat")
    for pstat in response:
      for prop in pstat.findAll(NS & "prop"):
        for p in prop:
          let tag = p.tag.replace(NS, "")
          properties[href.innerText].add(tag)

  return properties


proc download*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
) {.async.} =
  let resp = await wd.request(
    path,
    httpMethod = "GET",
  )

  if resp.code != HttpCode(200):
    operationFailed(await resp.body, resp.code)

  var output = newFileStream(destination, fmWrite)

  if not isNil(output):
    output.write(await resp.body)
    output.close()


proc upload*(
  wd: AsyncWebDAV,
  filepath: string,
  destination: string,
) {.async.} =
  var strm = newFileStream(filepath, fmRead)

  if isNil(strm):
    operationFailed("File \"" & filepath & "\" not found")

  let reqBody = strm.readAll()

  let resp = await wd.request(
    destination,
    httpMethod = "PUT",
    body = reqBody,
  )

  if resp.code != HttpCode(201):
    operationFailed(await resp.body, resp.code)


proc mkdir*(
  wd: AsyncWebDAV,
  path: string,
) {.async.} =
  let resp = await wd.request(
    path,
    httpMethod = "MKCOL",
  )

  if resp.code != HttpCode(201):
    operationFailed(await resp.body, resp.code)


proc rm*(
  wd: AsyncWebDAV,
  path: string,
) {.async.} =
  ## Delete a file or directory. If path is a directory,
  ## all resources within will be deleted recursively.
  let resp = await wd.request(
    path,
    httpMethod = "DELETE",
  )

  if resp.code != HttpCode(204):
    operationFailed(await resp.body, resp.code)


proc mv*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
  overwrite: bool = false,
  depth: Depth = INF,
) {.async.} =
  ## Move a resource from one location to another.
  var overwriteValue = "F"
  if overwrite:
    overwriteValue = "T"

  let resp = await wd.request(
    path,
    httpMethod = "MOVE",
    headers = some(
      @[("Destination", $(parseUri(wd.address) / destination)),
        ("Overwrite", overwriteValue),
        ("Depth", $depth)]
    )
  )

  if resp.code != HttpCode(204) and resp.code != HttpCode(201):
    operationFailed(await resp.body, resp.code)


proc cp*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
  overwrite: bool = false,
  depth: Depth = INF,
) {.async.} =
  ## Copy a resource to another location.
  var overwriteValue = "F"
  if overwrite:
    overwriteValue = "T"

  let resp = await wd.request(
    path,
    httpMethod = "COPY",
    headers = some(
      @[("Destination", $(parseUri(wd.address) / destination)),
        ("Overwrite", overwriteValue),
        ("Depth", $depth)]
    )
  )

  if resp.code != HttpCode(204) and resp.code != HttpCode(201):
    operationFailed(await resp.body, resp.code)

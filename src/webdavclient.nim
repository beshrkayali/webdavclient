from sequtils import zip
from strutils import replace
import strtabs, tables, base64, xmlparser, xmltree, streams
import uri, asyncdispatch, httpClient


type
  OperationFailed* = object of Exception

type
  filesTable = Table[string, string]


proc operationFailed*(msg: string) {.noreturn.} =
  ## raises an OperationFailed exception with message `msg`.
  var e: ref OperationFailed
  new(e)
  e.msg = msg
  raise e


type AsyncWebDAV* = ref object of RootObj
    client*: AsyncHttpClient
    path*: string
    address*: string
    username*: string
    password*: string

proc newAsyncWebDAV*(address: string, username: string, password: string, path: string): AsyncWebDAV =
  let fulladdr = parseUri(address) / path
  let client = newAsyncHttpClient()

  client.headers["Authorization"] = "Basic " & base64.encode(username & ":" & password)

  AsyncWebDAV(
    client: client,
    path: path,
    address: $fulladdr,
    username: username,
    password: password,
  )


proc ls*(
  wd: AsyncWebDAV,
  path: string,
  props: seq[string],
  namespaces: StringTableRef,
  depth: int = 0,
): Future[Table[string, filesTable]] {.async.} =

  var propNode = newElement("d:prop")
  var nsAttrs = {"xmlns:d": "DAV:"}.toXmlAttributes

  wd.client.headers["Depth"] = $depth

  for k, v in pairs(namespaces):
    nsAttrs[k] = v

  for p in props:
    let pNode = newElement(p)
    propNode.add(pNode)
    
  var reqXml = newElement("d:propfind")
  reqXml.attrs = nsAttrs
  reqXml.add(propNode)

  let reqBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" & $reqXml

  let resp = await wd.client.request($(parseUri(wd.address) / path), httpMethod = "PROPFIND", body=reqBody)

  if resp.code != HttpCode(207):
    let error = parseXml(await resp.body).child("s:message").innerText
    operationFailed(error)

  let body = await resp.body
  let node: XmlNode = parseXml(body)
  var files = initTable[string, filesTable]()
  var hrefs = newSeq[string]()
  var propsTables = newSeq[filesTable]()

  for item in node:
    let href = item.child("d:href")
    let props = item.child("d:propstat")
    hrefs.add(href.innerText.replace(wd.path, ""))

    var propsTable: filesTable
    for prop in props.findAll("d:prop"):
      for p in prop:
        propsTable[p.tag] = p.innerText

    propsTables.add(propsTable)

  for pairs in zip(hrefs, propsTables):
    let (href, props) = pairs
    files[href] = props

  return files

proc download*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
) {.async.} =
  let resp = await wd.client.request($(parseUri(wd.address) / path), httpMethod = "GET")

  if resp.code != HttpCode(200):
    let error = parseXml(await resp.body).child("s:message").innerText
    operationFailed(error)

  var output = newFileStream(destination, fmWrite)

  if not isNil(output):
    output.write(await resp.body)
    output.close()


proc upload*(
  wd: AsyncWebDAV,
  path: string,
  filepath: string,
) {.async.} =
  var strm = newFileStream(filepath, fmRead)

  if isNil(strm):
    operationFailed("File \"" & filepath & "\" not found")
    
  let body = strm.readAll()

  let resp = await wd.client.request($(parseUri(wd.address) / path), httpMethod = "PUT", body=body)

  if resp.code != HttpCode(201):
    let error = parseXml(await resp.body).child("s:message").innerText
    operationFailed(error)


proc mkdir*(
  wd: AsyncWebDAV,
  path: string,
) {.async.} =
  let resp = await wd.client.request($(parseUri(wd.address) / path), httpMethod = "MKCOL")

  if resp.code != HttpCode(201):
    let error = parseXml(await resp.body).child("s:message").innerText
    operationFailed(error)


proc rm*(
  wd: AsyncWebDAV,
  path: string,
) {.async.} =
  let resp = await wd.client.request($(parseUri(wd.address) / path), httpMethod = "DELETE")

  if resp.code != HttpCode(204):
    let error = parseXml(await resp.body).child("s:message").innerText
    operationFailed(error)


proc mv*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
) {.async.} =

  wd.client.headers["Destination"] = $(parseUri(wd.address) / destination)
  
  let resp = await wd.client.request($(parseUri(wd.address) / path), httpMethod = "MOVE")

  if resp.code != HttpCode(204):
    let error = parseXml(await resp.body).child("s:message").innerText
    operationFailed(error)


proc cp*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
) {.async.} =

  wd.client.headers["Destination"] = $(parseUri(wd.address) / destination)
  
  let resp = await wd.client.request($(parseUri(wd.address) / path), httpMethod = "COPY")

  if resp.code != HttpCode(204):
    let error = parseXml(await resp.body).child("s:message").innerText
    operationFailed(error)

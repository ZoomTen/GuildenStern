from os import osLastError, osErrorMsg, OSErrorCode
from posix import recv
from streams import StringStream, newStringStream, getPosition, setPosition, write
from strutils import find, parseInt
import strtabs
import guildenserver
export guildenserver, osLastError, osErrorMsg, OSErrorCode, recv, StringStream, newStringStream, getPosition

const
  MaxHeaderLength* {.intdefine.} = 1000
  MaxRequestLength* {.intdefine.} = 1000
  MaxResponseLength* {.intdefine.} = 100000

type
  HttpCtx* = ref object of Ctx
    requestlen*: int
    path*: int
    pathlen*: int
    methlen*: int
    bodystart*: int

var
  httprequest* {.threadvar.}: string


proc initHttpCtx*(ctx: HttpCtx, gs: ptr GuildenServer, socketdata: ptr SocketData) {.inline.} =
  ctx.gs = gs
  ctx.socketdata = socketdata
  ctx.requestlen = 0
  ctx.path = 0
  ctx.pathlen = 0
  ctx.methlen = 0
  ctx.bodystart = 0


proc notifyError*(ctx: HttpCtx, msg: string) {.inline.} =
  if ctx.gs.errorNotifier != nil: ctx.gs.errorNotifier(msg)
  else:
    if defined(fulldebug): echo msg


template checkRet*() =
  if ret < 1:
    if ret == -1:
      let lastError = osLastError().int
      if lastError != 2 and lastError != 9 and lastError != 32 and lastError != 104:
        ctx.notifyError("socket error: " & $lastError & " " & osErrorMsg(OSErrorCode(lastError)))
    elif ret < -1: ctx.notifyError("socket exception: " & getCurrentExceptionMsg())
    ctx.closeSocket()
    return false
      

proc parseRequestLine*(ctx: HttpCtx): bool {.gcsafe, raises: [].} =
  if ctx.requestlen < 13:
    when defined(fulldebug): echo "too short request (", ctx.requestlen,"): ", httprequest
    (ctx.closeSocket(); return false)

  while ctx.methlen < ctx.requestlen and httprequest[ctx.methlen] != ' ': ctx.methlen.inc
  if ctx.methlen == ctx.requestlen:
    when defined(fulldebug): echo "http method missing"
    (ctx.closeSocket(); return false)

  var i = ctx.methlen + 1
  let start = i
  while i < ctx.requestlen and httprequest[i] != ' ': i.inc()
  ctx.path = start
  ctx.pathlen = i - start
  if ctx.requestlen < ctx.path + ctx.pathlen + 9:
    when defined(fulldebug): echo ("parseRequestLine: no version")
    (ctx.closeSocket(); return false)
  
  if httprequest[ctx.path + ctx.pathlen + 1] != 'H' or httprequest[ctx.path + ctx.pathlen + 8] != '1':
    when defined(fulldebug): echo "request not HTTP/1.1: ", httprequest[ctx.path + ctx.pathlen + 1 .. ctx.path + ctx.pathlen + 8]
    (ctx.closeSocket(); return false)
  when defined(fulldebug): echo ctx.socketdata.port, ": ", httprequest[0 .. ctx.path + ctx.pathlen + 8]
  true


proc isHeaderreceived*(ctx: HttpCtx, previouslen, currentlen: int): bool =
  if currentlen < 4: return false
  if httprequest[currentlen-4] == '\c' and httprequest[currentlen-3] == '\l' and httprequest[currentlen-2] == '\c' and
  httprequest[currentlen-1] == '\l':
    ctx.bodystart = currentlen
    return true

  var i = if previouslen > 4: previouslen - 4 else: previouslen
  while i <= currentlen - 4:
    if httprequest[i] == '\c' and httprequest[i+1] == '\l' and httprequest[i+2] == '\c' and httprequest[i+3] == '\l':
      ctx.bodystart = i + 4
      return true
    inc i
  false


proc getContentLength*(ctx: HttpCtx): int {.raises: [].} =
  const length  = "content-length: ".len
  var start = httprequest.find("content-length: ")
  if start == -1: start = httprequest.find("Content-Length: ")
  if start == -1:
    when defined(fulldebug): echo "content-length header missing"
    return 0
  var i = start + length
  while i < ctx.requestlen and httprequest[i] != '\l': i += 1
  if i == ctx.requestlen: return 0
  try: return parseInt(httprequest[start .. i])
  except:
    when defined(fulldebug): echo "could not parse content-length from: ", httprequest[start .. i]
    return 0
  

proc getPath*(ctx: HttpCtx): string {.raises: [].} =
  if ctx.pathlen == 0: return
  return httprequest[ctx.path ..< ctx.path + ctx.pathlen]


proc isPath*(ctx: HttpCtx, apath: string): bool {.raises: [].} =
  if ctx.pathlen != apath.len: return false
  for i in 0 ..< ctx.pathlen:
    if httprequest[ctx.path + i] != apath[i]: return false
  return true


proc pathStarts*(ctx: HttpCtx, pathstart: string): bool {.raises: [].} =
  if ctx.pathlen < pathstart.len: return false
  for i in 0 ..< pathstart.len:
    if httprequest[ctx.path + i] != pathstart[i]: return false
  true


proc getMethod*(ctx: HttpCtx): string {.raises: [].} =
  if ctx.methlen == 0: return
  return httprequest[0 ..< ctx.methlen]


proc isMethod*(ctx: HttpCtx, amethod: string): bool {.raises: [].} =
  if ctx.methlen != amethod.len: return false
  for i in 0 ..< ctx.methlen:
    if httprequest[i] != amethod[i]: return false
  true


proc getHeaders*(ctx: HttpCtx): string =
  httprequest[0 .. ctx.bodystart - 4]


proc getBody*(ctx: HttpCtx): string =
  httprequest[ctx.bodystart ..< ctx.requestlen]
  

proc isBody*(ctx: HttpCtx, body: string): bool {.raises: [].} =
  let len = ctx.requestlen - ctx.bodystart
  if  len != body.len: return false
  for i in ctx.bodystart ..< ctx.bodystart + len:
    if httprequest[i] != body[i]: return false
  true


proc parseHeaders*(ctx: HttpCtx, fields: openArray[string], toarray: var openArray[string]) =
  assert(fields.len == toarray.len)
  var value = false
  var current: (string, string) = ("", "")
  var found = 0
  var i = 0

  while i <= ctx.requestlen - 4:
    case httprequest[i]
    of '\c':
      if httprequest[i+1] == '\l' and httprequest[i+2] == '\c' and httprequest[i+3] == '\l':
        if ctx.requestlen > i + 4: ctx.bodystart = i + 4
        return
    of ':':
      if value: current[1].add(':')
      value = true
    of ' ':
      if value:
        if current[1].len != 0: current[1].add(httprequest[i])
      else: current[0].add(httprequest[i])
    of '\l':
      let index = fields.find(current[0])
      if index != -1: toarray[index] = current[1]
      value = false
      current = ("", "")
      found += 1
      if found == toarray.len: return
    else:
      if value: current[1].add(httprequest[i])
      else: current[0].add(httprequest[i])
    i.inc


proc parseHeaders*(ctx: HttpCtx, headers: StringTableRef) =
  var value = false
  var current: (string, string) = ("", "")
  var i = 0

  while i <= ctx.requestlen - 4:
    case httprequest[i]
    of '\c':
      if httprequest[i+1] == '\l' and httprequest[i+2] == '\c' and httprequest[i+3] == '\l':
        if ctx.requestlen > i + 4: ctx.bodystart = i + 4
        return
    of ':':
      if value: current[1].add(':')
      value = true
    of ' ':
      if value:
        if current[1].len != 0: current[1].add(httprequest[i])
      else: current[0].add(httprequest[i])
    of '\l':
      echo current
      headers[current[0]] = current[1]
      value = false
      current = ("", "")
    else:
      if value: current[1].add(httprequest[i])
      else: current[0].add(httprequest[i])
    i.inc


proc append*(stringstream: StringStream, str: ptr string): bool {.raises: [].} =
  try: 
    if stringstream.getPosition() + str[].len() > MaxResponseLength: return false
    stringstream.write(str[])
  except: return false
  true


include httpout


proc replyStringStream*(ctx: HttpCtx, code: HttpCode=Http200, stringstream: StringStream, headers: ptr string) =
  let length = stringstream.getPosition()
  if length == 0: reply(ctx, code, nil, headers)
  else: reply(ctx, code, addr stringstream.data, headers, length)
## Websocket handler.
## 
## **Example:**
##
## .. code-block:: Nim
##
##    
##    import nativesockets
##    import guildenstern/[ctxws, ctxheader]
##    
##    var server = new GuildenServer
##    var socket = osInvalidSocket
##    
##    proc onUpgradeRequest(ctx: WsCtx): bool = socket = ctx.socketdata.socket; true
##    
##    proc onMessage(ctx: WsCtx) = echo "client says: ", ctx.getRequest()
##      
##    proc sendMessage() =
##      {.gcsafe.}: # in reality, use locks to make handling connected (web) sockets thread safe
##        if socket != osInvalidSocket:
##          let reply = "hello"
##          discard server.sendWs(socket, unsafeAddr reply)
##    
##    proc onLost(gs: ptr GuildenServer, data: ptr SocketData, lostsocket: SocketHandle) =
##      if lostsocket.int == socket.int:
##        echo "websocket connection lost"
##        {.gcsafe.}: socket = osInvalidSocket
##          
##    proc onRequest(ctx: HttpCtx) =
##      let html = """<!doctype html><title>WsCtx</title>
##      <script>
##      let websocket = new WebSocket("ws://" + location.host.slice(0, -1) + '1')
##      websocket.onmessage = function(evt) { document.getElementById("table").insertRow(0).insertCell(0).innerHTML = evt.data }
##      </script>
##      <body><button onclick="websocket.send('hallo')">say hallo</button><button onclick="websocket.close()">close</button><table id="table">"""
##      ctx.reply(Http200, unsafeAddr html)
##    
##    server.initHeaderCtx(onRequest, 5050)
##    server.initWsCtx(onUpgradeRequest, onMessage, 5051)
##    server.registerTimerhandler(sendMessage, 2000)
##    server.registerConnectionlosthandler(onLost)
##    echo "Point your browser to localhost:5050"
##    server.serve()

import nativesockets, net, posix, os, std/sha1, base64
from httpcore import Http101

when not defined(nimdoc):
  import guildenstern
  export guildenstern
else:
  import guildenserver, ctxhttp

from ctxheader import receiveHeader


const MaxWsRequestLength* {.intdefine.} = 100000

type
  Opcode* = enum
    Cont = 0x0                ## continuation frame
    Text = 0x1                ## text frame
    Binary = 0x2              ## binary frame
    Close = 0x8               ## connection close
    Ping = 0x9                ## ping
    Pong = 0xa                ## pong
    Fail = 0xe                ## protocol failure / connection lost in flight

  WsCtx* = ref object of HttpCtx
    opcode*: OpCode

  WsUpgradeRequestCallback =  proc(ctx: WsCtx): bool {.gcsafe, nimcall, raises: [].}
  WsMessageCallback = proc(ctx: WsCtx){.gcsafe, nimcall, raises: [].}

var
  WsCtxId: CtxId
  upgraderequestcallback: WsUpgradeRequestCallback
  messageCallback: WsMessageCallback
  
  wsresponseheader {.threadvar.}: string
  ctx {.threadvar.}: WsCtx 
  maskkey {.threadvar.}: array[4, char]
  
{.push checks: off.}

template `[]`(value: uint8, index: int): bool =
  ## Get bits from uint8, uint8[2] gets 2nd bit.
  (value and (1 shl (7 - index))) != 0

  #[
   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-------+-+-------------+-------------------------------+
  |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
  |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
  |N|V|V|V|       |S|             |   (if payload len==126/127)   |
  | |1|2|3|       |K|             |                               |
  +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
  |     Extended payload length continued, if payload len == 127  |
  + - - - - - - - - - - - - - - - +-------------------------------+
  |                               |Masking-key, if MASK set to 1  |
  +-------------------------------+-------------------------------+
  | Masking-key (continued)       |          Payload Data         |
  +-------------------------------- - - - - - - - - - - - - - - - +
  :                     Payload Data continued ...                :
  + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
  |                     Payload Data continued ...                |
  +---------------------------------------------------------------+]#


template error(msg: string) =
  let errormsg = "websocket " & $ctx.socketdata.socket & " fail: " & msg
  ctx.gs.notifyError(errormsg)
  when defined(fulldebug): echo errormsg
  ctx.opcode = Fail
  return -1

proc bytesRecv(fd: posix.SocketHandle, buffer: ptr char, size: int): int =
  return recv(fd, buffer, size, 0)


proc recvHeader(): int =
  if posix.SocketHandle(ctx.socketdata.socket).bytesRecv(request[0].addr, 2) != 2: error("no data")
  let b0 = request[0].uint8
  let b1 = request[1].uint8
  ctx.opcode = (b0 and 0x0f).Opcode
  if b0[1] or b0[2] or b0[3]: error("protocol")
  var expectedLen: int = 0

  let headerLen = uint(b1 and 0x7f)
  if headerLen == 0x7e:
    var lenstrlen = posix.SocketHandle(ctx.socketdata.socket).bytesRecv(request[0].addr, 2)
    if lenstrlen != 2: error("length")    
    expectedLen = nativesockets.htons(cast[ptr uint16](request[0].addr)[]).int
  elif headerLen == 0x7f:
    var lenstrlen = posix.SocketHandle(ctx.socketdata.socket).bytesRecv(request[0].addr, 8)
    if lenstrlen != 8: error("length")
  else: expectedLen = headerLen.int

  let maskKeylen = posix.SocketHandle(ctx.socketdata.socket).bytesRecv(maskkey[0].addr, 4)
  if maskKeylen != 4: error("length")

  if expectedLen > MaxWsRequestLength: error("Maximum request size bound to be exceeded: " & $(expectedLen))
  
  return expectedLen


proc recvFrame() =
  var expectedlen: int  
  expectedlen = recvHeader()
  if ctx.opcode in [Fail, Close]: return
  while true:
    if shuttingdown: (ctx.opcode = Fail; return)
    let ret =
      if ctx.requestlen == 0: recv(ctx.socketdata.socket, addr request[0], expectedLen.cint, 0x40)
      else: recv(ctx.socketdata.socket, addr request[ctx.requestlen], (expectedLen - ctx.requestlen).cint, 0)
    if shuttingdown: (ctx.opcode = Fail; return)

    if ret == 0: (ctx.closeSocket(); ctx.opcode = Fail; return)
    if ret == -1:
      let lastError = osLastError().int
      if lastError != 2 and lastError != 9 and lastError != 32 and lastError != 104:
        ctx.gs.notifyError("websocket error: " & $lastError & " " & osErrorMsg(OSErrorCode(lastError)))
      ctx.opcode = Fail
      return

    ctx.requestlen += ret
    if ctx.requestlen == expectedlen: return


proc receiveWs() =
  ctx.requestlen = 0
  try:
    recvFrame()
    if ctx.opcode in [Fail, Close]: return
    while ctx.opcode == Cont: recvFrame()
    for i in 0 ..< ctx.requestlen: request[i] = (request[i].uint8 xor maskkey[i mod 4].uint8).char
  except:
    ctx.gs.notifyError("receiveWs: " & getCurrentExceptionMsg())
    ctx.opcode = Fail


proc nibbleFromChar(c: char): int =
  case c:
    of '0'..'9': (ord(c) - ord('0'))
    of 'a'..'f': (ord(c) - ord('a') + 10)
    of 'A'..'F': (ord(c) - ord('A') + 10)
    else: 255


proc decodeBase16(str: string): string =
  result = newString(str.len div 2)
  for i in 0 ..< result.len:
    result[i] = chr(
      (nibbleFromChar(str[2 * i]) shl 4) or
      nibbleFromChar(str[2 * i + 1]))

proc replyHandshake(): bool =
  if not ctx.receiveHeader(): return false
  var headers = [""]  
  ctx.parseHeaders(["sec-websocket-key"], headers)
  if headers[0] == "": return false
  if not ctx.upgraderequestcallback(): return false
  let 
    sh = secureHash(headers[0] & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    acceptKey = base64.encode(decodeBase16($sh))
  ctx.reply(Http101, ["Sec-WebSocket-Accept: " & acceptKey, "Connection: Upgrade", "Upgrade: webSocket"])
  true

proc handleWsUpgradehandshake(gs: ptr GuildenServer, data: ptr SocketData) {.gcsafe, nimcall, raises: [].} =
  if ctx == nil:
    ctx = new WsCtx
    initHttpCtx(ctx, gs, data)
    if request.len < MaxWsRequestLength + 1: request = newString(MaxWsRequestLength + 1)
  ctx.gs = gs
  ctx.socketdata = data
  ctx.requestlen = 0
  if replyHandshake(): data.ctxid = WsCtxId
  else:
    ctx.replyCode(Http204)
    sleep(3000)
    ctx.closeSocket()


proc handleWsMessage(gs: ptr GuildenServer, data: ptr SocketData) {.gcsafe, nimcall, raises: [].} =
  if ctx == nil:
    ctx = new WsCtx
    initHttpCtx(ctx, gs, data)
    if request.len < MaxWsRequestLength + 1: request = newString(MaxWsRequestLength + 1)
  ctx.gs = gs
  ctx.socketdata = data
  ctx.requestlen = 0
  receiveWs()
  if ctx.opcode in [Fail, Close]:
    let lostsocket = data.socket    
    ctx.closeSocket()
    handleConnectionlost(gs, data, lostsocket)
  else:
    {.gcsafe.}: messageCallback(ctx)
  

proc initWsCtx*(gs: var GuildenServer, onwsupgraderequestcallback: WsUpgradeRequestCallback, onwsmessage: WsMessageCallback, port: int) =
  {.gcsafe.}:
    upgraderequestcallback = onwsupgraderequestcallback
    messageCallback = onwsmessage
    discard gs.registerHandler(handleWsUpgradehandshake, port)
    WsCtxId = gs.registerHandler(handleWsMessage, -1)


proc send(gs: ptr GuildenServer, socket: posix.SocketHandle, text: ptr string, length: int = -1): bool =
  let len = if length == -1: text[].len else: length
  var sent = 0
  while sent < len:
    if shuttingdown: return false    
    let ret = send(socket, addr text[sent], len - sent, 0)
    if ret < 1:
      if ret == -1:
        let lastError = osLastError().int
        if lastError != 2 and lastError != 9 and lastError != 32 and lastError != 104:
          gs.notifyError("websocket error: " & $lastError & " " & osErrorMsg(OSErrorCode(lastError)))
      elif ret < -1: gs.notifyError("websocket exception: " & getCurrentExceptionMsg())
      gs.closeSocket(nativesockets.SocketHandle(socket))
      return false
    sent.inc(ret)
    if sent == len: return true
  

proc createWsHeader(len: int, binary = false) =
  wsresponseheader = ""
  var b0 = if binary: (0x2.uint8 and 0x0f) else: (0x1.uint8 and 0x0f)
  b0 = b0 or 128u8

  var b1 = 0u8
  if len <= 125: b1 = len.uint8
  elif len > 125 and len <= 0xffff: b1 = 126u8
  else: b1 = 127u8

  wsresponseheader.add(b0.char)
  wsresponseheader.add(b1.char)
    
  if len > 125 and len <= 0xffff:
    wsresponseheader.add($nativesockets.htons(len.uint16))
  elif len > 0xffff:
    wsresponseheader.add char((len shr 56) and 255)
    wsresponseheader.add char((len shr 48) and 255)
    wsresponseheader.add char((len shr 40) and 255)
    wsresponseheader.add char((len shr 32) and 255)
    wsresponseheader.add char((len shr 24) and 255)
    wsresponseheader.add char((len shr 16) and 255)
    wsresponseheader.add char((len shr 8) and 255)
    wsresponseheader.add char(len and 255)


proc sendWs*(gs: GuildenServer, socket: nativesockets.SocketHandle, text: ptr string, length: int = -1, binary = false): bool =
  if length == 0 or text == nil: return
  let len = if length == -1: text[].len else: length
  createWsHeader(len, binary)
  if send(unsafeAddr gs, posix.SocketHandle(socket), addr wsresponseheader): return send(unsafeAddr gs, posix.SocketHandle(socket), text, len)


proc replyWs*(ctx: Ctx, text: ptr string, length = -1, binary = false): bool {.inline.} =
  return ctx.gs[].sendWs(ctx.socketdata.socket, text, length, binary)
    
{.pop.}
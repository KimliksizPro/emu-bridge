#!/usr/bin/env bash

echo "===================================================="
echo "🚀 EVRENSEL ADB WEBUSB KÖPRÜSÜ (SIFIR BAĞIMLILIK)"
echo "===================================================="

adb start-server 2>/dev/null
mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')

if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "❌ Bağlı cihaz bulunamadı! 'adb devices' ile telefonun veya emülatörün bağlı olduğundan emin ol."
    exit 1
fi

DEV="${DEVICES[0]}"
if [ ${#DEVICES[@]} -gt 1 ]; then
    echo "📱 Birden fazla cihaz bulundu, hangisine APK kurulacak?"
    select SDEV in "${DEVICES[@]}"; do
        if [ -n "$SDEV" ]; then DEV="$SDEV"; break; fi
    done
fi

echo "🎯 Seçilen Cihaz: $DEV"

# Tarayıcı Console için JS Kodunu Hazırla ve Panoya Kopyala
read -r -d '' JS_CODE << 'JSEOF'
(() => {
  const WS_URL = "ws://127.0.0.1:8080";
  let ws = null, rxPackets = [], pendingReads = [];

  function resetState(targetWs) {
    if (targetWs && targetWs !== ws) return;
    if (ws) {
      ws.onclose = null;
      ws.onerror = null;
      ws.onmessage = null;
      try { ws.close(); } catch (e) {}
      ws = null;
    }
    rxPackets = [];
    while (pendingReads.length > 0) {
      const { reject } = pendingReads.shift();
      if (reject) reject(new Error("Reset"));
    }
  }

  function enqueueUsbPacket(pkt) {
    console.log(`[Bridge <- PC] ${pkt.byteLength} byte alındı`);
    if (pendingReads.length > 0) {
      const { length, resolve } = pendingReads.shift();
      const chunk = pkt.slice(0, length);
      if (pkt.length > length) rxPackets.unshift(pkt.slice(length));
      resolve({ data: new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength), status: "ok" });
    } else {
      rxPackets.push(pkt);
    }
  }

  const fakeUsbDevice = {
    vendorId: 0x18d1, productId: 0x4ee7,
    usbVersionMajor: 2, usbVersionMinor: 0, usbVersionSubminor: 0,
    deviceClass: 0, deviceSubclass: 0, deviceProtocol: 0,
    productName: "Universal ADB Bridge", manufacturerName: "Google", serialNumber: "universal-adb",
    opened: false,
    configurations: [{
      configurationValue: 1, configurationName: "ADB",
      interfaces: [{
        interfaceNumber: 0, claimed: true,
        alternate: {
          alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 0x01,
          endpoints: [
            { endpointNumber: 1, direction: "in", type: "bulk", packetSize: 16384 },
            { endpointNumber: 2, direction: "out", type: "bulk", packetSize: 16384 }
          ]
        },
        alternates: [{
          alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 0x01,
          endpoints: [
            { endpointNumber: 1, direction: "in", type: "bulk", packetSize: 16384 },
            { endpointNumber: 2, direction: "out", type: "bulk", packetSize: 16384 }
          ]
        }]
      }]
    }],
    get configuration() { return this.configurations[0]; },
    async open() {
      resetState();
      console.log("[Bridge] WebSocket bağlanıyor:", WS_URL);
      const sock = new WebSocket(WS_URL);
      sock.binaryType = "arraybuffer";
      ws = sock;
      await new Promise((res, rej) => { sock.onopen = res; sock.onerror = rej; });
      sock.onmessage = (e) => enqueueUsbPacket(new Uint8Array(e.data));
      sock.onclose = () => resetState(sock);
      this.opened = true;
      console.log("[Bridge] ⚡ Evrensel ADB Köprüsü Açıldı!");
    },
    async close() { resetState(); this.opened = false; },
    async selectConfiguration() {}, async claimInterface() {}, async selectAlternateInterface() {},
    async releaseInterface() {}, async clearHalt() {}, async reset() {},
    async transferIn(ep, length) {
      if (rxPackets.length > 0) {
        const pkt = rxPackets.shift();
        const chunk = pkt.slice(0, length);
        if (pkt.length > length) rxPackets.unshift(pkt.slice(length));
        return { data: new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength), status: "ok" };
      }
      return new Promise((resolve, reject) => pendingReads.push({ length, resolve, reject }));
    },
    async transferOut(ep, data) {
      const u8 = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      if (u8.byteLength === 0) return { bytesWritten: 0, status: "ok" };
      console.log(`[Bridge -> PC] ${u8.byteLength} byte gönderildi`);
      if (ws && ws.readyState === 1) ws.send(u8);
      return { bytesWritten: u8.byteLength, status: "ok" };
    }
  };

  Object.defineProperty(navigator.usb, "requestDevice", { value: async () => fakeUsbDevice, configurable: true, writable: true });
  Object.defineProperty(navigator.usb, "getDevices", { value: async () => [fakeUsbDevice], configurable: true, writable: true });
  console.log("✅ [Universal Bridge] Aktif! Şimdi sitedeki Install / Cihaz Seç butonuna basabilirsin.");
})();
JSEOF

if command -v wl-copy >/dev/null 2>&1; then
    echo "$JS_CODE" | wl-copy
    echo "📋 JS Kodu panoya otomatik kopyalandı! (Tarayıcı F12 Console'da direkt Ctrl+V yap)"
elif command -v xclip >/dev/null 2>&1; then
    echo "$JS_CODE" | xclip -selection clipboard
    echo "📋 JS Kodu panoya otomatik kopyalandı! (Tarayıcı F12 Console'da direkt Ctrl+V yap)"
fi

fuser -k 8080/tcp 2>/dev/null

# Yerleşik Node.js modülleriyle (http, crypto, net) sıfır bağımlılıklı WebSocket -> ADB (5037) Köprüsü
exec node -e '
const http = require("http");
const crypto = require("crypto");
const net = require("net");
const SERIAL = process.argv[1];

function wsSend(socket, buf, opcode = 0x82) {
  if (socket.destroyed) return;
  const len = buf.length;
  let header;
  if (len < 126) {
    header = Buffer.from([opcode, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  socket.write(Buffer.concat([header, buf]));
}

function makeAdbPacket(cmdStr, arg0, arg1, payload = Buffer.alloc(0)) {
  const buf = Buffer.alloc(24);
  buf.write(cmdStr, 0, 4, "ascii");
  buf.writeUInt32LE(arg0 >>> 0, 4);
  buf.writeUInt32LE(arg1 >>> 0, 8);
  buf.writeUInt32LE(payload.length >>> 0, 12);
  let sum = 0;
  for (let i = 0; i < payload.length; i++) sum = (sum + payload[i]) >>> 0;
  buf.writeUInt32LE(sum, 16);
  buf.writeUInt32LE((~buf.readUInt32LE(0)) >>> 0, 20);
  return { header: buf, payload };
}

function sendPacketToBrowser(socket, cmdStr, arg0, arg1, payload = Buffer.alloc(0)) {
  const { header, payload: pl } = makeAdbPacket(cmdStr, arg0, arg1, payload);
  wsSend(socket, header);
  if (pl.length > 0) wsSend(socket, pl);
}

const server = http.createServer((req, res) => {
  res.writeHead(200);
  res.end("ADB Bridge Running");
});

server.on("upgrade", (req, socket) => {
  const key = req.headers["sec-websocket-key"];
  const accept = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
    "Upgrade: websocket\r\n" +
    "Connection: Upgrade\r\n" +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );

  console.log("⚡ Tarayıcı bağlandı! (TLS/RSA Bypass devrede)");
  let wsBuf = Buffer.alloc(0);
  let adbRxBuf = Buffer.alloc(0);
  const streams = new Map();

  function getStream(arg0, arg1) {
    return streams.get(arg0) || streams.get(arg1 - 1000) || streams.get(arg1);
  }

  function flushStream(st) {
    if (st.closed || st.waitingOkay) return;
    if (st.txQueue.length > 0) {
      const chunk = st.txQueue.shift();
      st.waitingOkay = true;
      sendPacketToBrowser(socket, "WRTE", st.remoteId, st.localId, chunk);
    } else if (st.eof) {
      st.closed = true;
      streams.delete(st.localId);
      sendPacketToBrowser(socket, "CLSE", st.remoteId, st.localId);
    }
  }

  function enqueueStreamData(st, buf) {
    // 15360 byte (15 KB) dilimler: 16384 (USB packetSize) tam katı olmadığı için ZLP beklemesine takılmaz
    for (let i = 0; i < buf.length; i += 15360) {
      st.txQueue.push(Buffer.from(buf.subarray(i, i + 15360)));
    }
    flushStream(st);
  }

  socket.on("data", (chunk) => {
    wsBuf = Buffer.concat([wsBuf, chunk]);
    while (wsBuf.length >= 2) {
      const b0 = wsBuf[0];
      const b1 = wsBuf[1];
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let payloadLen = b1 & 0x7f;
      let offset = 2;
      if (payloadLen === 126) {
        if (wsBuf.length < 4) return;
        payloadLen = wsBuf.readUInt16BE(2);
        offset = 4;
      } else if (payloadLen === 127) {
        if (wsBuf.length < 10) return;
        payloadLen = Number(wsBuf.readBigUInt64BE(2));
        offset = 10;
      }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (wsBuf.length < offset + payloadLen) return;
      const payload = Buffer.from(wsBuf.subarray(offset, offset + payloadLen));
      if (masked) {
        const mask = wsBuf.subarray(maskOffset, maskOffset + 4);
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      }
      wsBuf = wsBuf.subarray(offset + payloadLen);
      if (opcode === 0x08) { socket.end(); return; }
      if (opcode === 0x09) { wsSend(socket, payload, 0x8a); continue; }
      if (opcode === 0x00 || opcode === 0x01 || opcode === 0x02) onWsData(payload);
    }
  });

  function onWsData(buf) {
    adbRxBuf = Buffer.concat([adbRxBuf, buf]);
    while (adbRxBuf.length >= 24) {
      const len = adbRxBuf.readUInt32LE(12);
      if (adbRxBuf.length < 24 + len) break;
      const cmd = adbRxBuf.toString("ascii", 0, 4);
      const arg0 = adbRxBuf.readUInt32LE(4);
      const arg1 = adbRxBuf.readUInt32LE(8);
      const payload = Buffer.from(adbRxBuf.subarray(24, 24 + len));
      adbRxBuf = adbRxBuf.subarray(24 + len);
      handleCommand(cmd, arg0, arg1, payload);
    }
  }

  function handleCommand(cmd, arg0, arg1, payload) {
    if (cmd === "CNXN") {
      console.log("🤝 CNXN alındı -> Cihaz bağlantısı onaylandı!");
      sendPacketToBrowser(socket, "CNXN", 0x01000000, 256 * 1024, Buffer.from("device::ro.product.name=bridge;\0"));
    } else if (cmd === "OPEN") {
      const localId = arg0;
      const remoteId = localId + 1000;
      const svcBuf = payload[payload.length - 1] === 0 ? payload.subarray(0, payload.length - 1) : payload;
      const serviceLog = svcBuf.toString("utf8").replace(/\0/g, " ");
      console.log(`📂 Kanal açılıyor [${localId}]: ${serviceLog}`);

      const adbSock = net.connect(5037, "127.0.0.1", () => {
        const tp = Buffer.from(`host:transport:${SERIAL}`, "utf8");
        const tpLen = Buffer.from(tp.length.toString(16).padStart(4, "0"), "ascii");
        adbSock.write(Buffer.concat([tpLen, tp]));
      });

      const st = {
        sock: adbSock,
        localId,
        remoteId,
        txQueue: [],
        waitingOkay: false,
        eof: false,
        closed: false
      };

      let step = 0;
      let statusBuf = Buffer.alloc(0);

      adbSock.on("data", (chunk) => {
        if (step < 2) {
          statusBuf = Buffer.concat([statusBuf, chunk]);
          while (step < 2 && statusBuf.length >= 4) {
            const status = statusBuf.toString("ascii", 0, 4);
            statusBuf = statusBuf.subarray(4);
            if (status === "OKAY") {
              step++;
              if (step === 1) {
                const svcLen = Buffer.from(svcBuf.length.toString(16).padStart(4, "0"), "ascii");
                adbSock.write(Buffer.concat([svcLen, svcBuf]));
              } else if (step === 2) {
                streams.set(localId, st);
                sendPacketToBrowser(socket, "OKAY", remoteId, localId);
                if (statusBuf.length > 0) {
                  enqueueStreamData(st, statusBuf);
                  statusBuf = Buffer.alloc(0);
                }
              }
            } else {
              adbSock.destroy();
              sendPacketToBrowser(socket, "CLSE", 0, localId);
              return;
            }
          }
        } else {
          enqueueStreamData(st, chunk);
        }
      });

      adbSock.on("end", () => {
        if (streams.has(localId)) {
          st.eof = true;
          flushStream(st);
        }
      });
      adbSock.on("error", () => {
        if (!st.closed) {
          st.closed = true;
          streams.delete(localId);
          sendPacketToBrowser(socket, "CLSE", remoteId, localId);
        }
      });
    } else if (cmd === "WRTE") {
      const st = getStream(arg0, arg1);
      if (st && !st.closed) {
        st.sock.write(payload, () => {
          sendPacketToBrowser(socket, "OKAY", st.remoteId, st.localId);
        });
      }
    } else if (cmd === "OKAY") {
      const st = getStream(arg0, arg1);
      if (st) {
        st.waitingOkay = false;
        flushStream(st);
      }
    } else if (cmd === "CLSE") {
      const st = getStream(arg0, arg1);
      if (st && !st.closed) {
        st.closed = true;
        streams.delete(st.localId);
        st.sock.end();
        sendPacketToBrowser(socket, "CLSE", st.remoteId, st.localId);
      }
    }
  }

  socket.on("close", () => {
    for (const st of streams.values()) st.sock.destroy();
    streams.clear();
  });
});

server.listen(8080, "127.0.0.1", () => {
  console.log("🚀 Köprü Hazır: ws://127.0.0.1:8080 -> " + SERIAL);
  console.log("====================================================");
});
' "$DEV"

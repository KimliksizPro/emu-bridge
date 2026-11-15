#!/usr/bin/env python3
import asyncio
import subprocess
import http
import websockets

BRIDGE_JS = r"""
(() => {
  if (window.__emuBridgeActive) {
    console.log("⚡ Köprü zaten aktif!");
    return;
  }
  window.__emuBridgeActive = true;
  const WS_URL = "ws://127.0.0.1:8080";
  let ws = null, byteBuffer = new Uint8Array(0), rxPackets = [], pendingReads = [], expectedPayloadLength = null;

  function processStream(newChunk) {
    const merged = new Uint8Array(byteBuffer.length + newChunk.length);
    merged.set(byteBuffer, 0);
    merged.set(newChunk, byteBuffer.length);
    byteBuffer = merged;

    while (true) {
      if (expectedPayloadLength === null) {
        if (byteBuffer.length >= 24) {
          const headerPacket = byteBuffer.slice(0, 24);
          const view = new DataView(headerPacket.buffer, headerPacket.byteOffset, 24);
          const cmd = view.getUint32(0, true), dataLength = view.getUint32(12, true);
          const validCmds = [0x4e584e43, 0x48545541, 0x4e45504f, 0x59414b4f, 0x45545257, 0x45534c43];
          if (validCmds.includes(cmd)) {
            byteBuffer = byteBuffer.slice(24);
            enqueueUsbPacket(headerPacket);
            expectedPayloadLength = dataLength > 0 ? dataLength : null;
          } else {
            enqueueUsbPacket(byteBuffer);
            byteBuffer = new Uint8Array(0);
            break;
          }
        } else break;
      } else {
        if (byteBuffer.length >= expectedPayloadLength) {
          const payloadPacket = byteBuffer.slice(0, expectedPayloadLength);
          byteBuffer = byteBuffer.slice(expectedPayloadLength);
          expectedPayloadLength = null;
          enqueueUsbPacket(payloadPacket);
        } else break;
      }
    }
  }

  function enqueueUsbPacket(pkt) {
    if (pendingReads.length > 0) {
      const { length, resolve } = pendingReads.shift();
      const chunk = pkt.slice(0, length);
      if (pkt.length > length) rxPackets.unshift(pkt.slice(length));
      resolve({ data: new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength), status: "ok" });
    } else rxPackets.push(pkt);
  }

  const fakeUsbDevice = {
    vendorId: 0x18d1, productId: 0x4ee7, usbVersionMajor: 2, usbVersionMinor: 0, usbVersionSubminor: 0,
    deviceClass: 0, deviceSubclass: 0, deviceProtocol: 0,
    productName: "Android Emulator (Auto-Bridge)", manufacturerName: "Google", serialNumber: "emulator-5554",
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
      ws = new WebSocket(WS_URL);
      ws.binaryType = "arraybuffer";
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
      ws.onmessage = (e) => processStream(new Uint8Array(e.data));
      this.opened = true;
    },
    async close() { if (ws) ws.close(); this.opened = false; },
    async selectConfiguration() {}, async claimInterface() {}, async selectAlternateInterface() {},
    async releaseInterface() {}, async clearHalt() {}, async reset() {},
    async transferIn(ep, length) {
      if (rxPackets.length > 0) {
        const pkt = rxPackets.shift(), chunk = pkt.slice(0, length);
        if (pkt.length > length) rxPackets.unshift(pkt.slice(length));
        return { data: new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength), status: "ok" };
      }
      return new Promise((resolve) => pendingReads.push({ length, resolve }));
    },
    async transferOut(ep, data) {
      const u8 = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      ws.send(u8);
      return { bytesWritten: u8.byteLength, status: "ok" };
    }
  };

  navigator.usb.requestDevice = async () => fakeUsbDevice;
  navigator.usb.getDevices = async () => [fakeUsbDevice];
  console.log("✅ Emülatör WebUSB Köprüsü Otomatik Yüklendi!");
})();
"""

# HTTP üzerinden /bridge.js istendiğinde JS kodunu döndürür (CORS destekli)
def process_request(connection, request):
    if request.path == "/bridge.js":
        headers = websockets.Headers([
            ("Content-Type", "application/javascript; charset=utf-8"),
            ("Access-Control-Allow-Origin", "*"),
        ])
        return websockets.http11.Response(200, "OK", headers, BRIDGE_JS.encode("utf-8"))
    return None

async def handle_ws(ws):
    print("⚡ Tarayıcı bağlandı -> Emülatör (127.0.0.1:5555) aktarımı başladı!")
    reader, writer = await asyncio.open_connection("127.0.0.1", 5555)

    async def ws_to_tcp():
        try:
            async for msg in ws:
                if isinstance(msg, bytes):
                    writer.write(msg)
                    await writer.drain()
        except Exception:
            pass
        finally:
            writer.close()

    async def tcp_to_ws():
        try:
            while True:
                data = await reader.read(16384)
                if not data:
                    break
                await ws.send(data)
        except Exception:
            pass
        finally:
            await ws.close()

    await asyncio.gather(ws_to_tcp(), tcp_to_ws())
    print("🔌 Bağlantı tamamlandı / kapandı.")

async def main():
    print("🛑 Yerel ADB sunucusu kapatılıyor (adb kill-server)...")
    subprocess.run(["adb", "kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # wl-copy (Wayland) varsa tek satırlık yükleyiciyi otomatik panoya kopyalar
    one_liner = 'fetch("http://127.0.0.1:8080/bridge.js").then(r=>r.text()).then(eval)'
    try:
        subprocess.run(["wl-copy", one_liner], check=False)
        print(f"📋 Panoya otomatik kopyalandı: {one_liner}")
    except FileNotFoundError:
        pass

    print("🚀 Sunucu Aktif!")
    print("   ├─ WebSocket Köprüsü : ws://127.0.0.1:8080")
    print("   └─ JS Enjektör URL   : http://127.0.0.1:8080/bridge.js")
    async with websockets.serve(handle_ws, "127.0.0.1", 8080, process_request=process_request):
        await asyncio.Future()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Kapatıldı.")

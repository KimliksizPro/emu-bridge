#!/usr/bin/env bash

# 1. Açık emülatörü ve portunu otomatik bul (Varsayılan: 5555)
EMU_SERIAL=$(adb devices | grep -oE 'emulator-[0-9]+' | head -n 1)
if [ -n "$EMU_SERIAL" ]; then
    CONSOLE_PORT=${EMU_SERIAL#emulator-}
    ADB_PORT=$((CONSOLE_PORT + 1))
else
    ADB_PORT=5555
fi

echo "🔍 Hedef Emülatör ADB Portu: 127.0.0.1:$ADB_PORT"

# 2. Yerel ADB sunucusunu kapat ki portu meşgul etmesin
echo "🛑 Yerel ADB sunucusu kapatılıyor (adb kill-server)..."
adb kill-server 2>/dev/null

# 3. JS Köprü Kodunu Hazırla
read -r -d '' JS_CODE << 'JSEOF'
(() => {
  const WS_URL = "ws://127.0.0.1:8080";
  let ws = null, byteBuffer = new Uint8Array(0), rxPackets = [], pendingReads = [], expectedPayloadLength = null;
  function processStream(newChunk) {
    const merged = new Uint8Array(byteBuffer.length + newChunk.length);
    merged.set(byteBuffer, 0); merged.set(newChunk, byteBuffer.length); byteBuffer = merged;
    while (true) {
      if (expectedPayloadLength === null) {
        if (byteBuffer.length >= 24) {
          const headerPacket = byteBuffer.slice(0, 24);
          const view = new DataView(headerPacket.buffer, headerPacket.byteOffset, 24);
          const cmd = view.getUint32(0, true), dataLength = view.getUint32(12, true);
          if ([0x4e584e43, 0x48545541, 0x4e45504f, 0x59414b4f, 0x45545257, 0x45534c43].includes(cmd)) {
            byteBuffer = byteBuffer.slice(24); enqueueUsbPacket(headerPacket);
            expectedPayloadLength = dataLength > 0 ? dataLength : null;
          } else { enqueueUsbPacket(byteBuffer); byteBuffer = new Uint8Array(0); break; }
        } else break;
      } else {
        if (byteBuffer.length >= expectedPayloadLength) {
          const payloadPacket = byteBuffer.slice(0, expectedPayloadLength);
          byteBuffer = byteBuffer.slice(expectedPayloadLength); expectedPayloadLength = null;
          enqueueUsbPacket(payloadPacket);
        } else break;
      }
    }
  }
  function enqueueUsbPacket(pkt) {
    if (pendingReads.length > 0) {
      const { length, resolve } = pendingReads.shift(), chunk = pkt.slice(0, length);
      if (pkt.length > length) rxPackets.unshift(pkt.slice(length));
      resolve({ data: new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength), status: "ok" });
    } else rxPackets.push(pkt);
  }
  const fakeUsbDevice = {
    vendorId: 0x18d1, productId: 0x4ee7, usbVersionMajor: 2, usbVersionMinor: 0, usbVersionSubminor: 0,
    deviceClass: 0, deviceSubclass: 0, deviceProtocol: 0,
    productName: "Android Emulator (Bash Bridge)", manufacturerName: "Google", serialNumber: "emulator-5554", opened: false,
    configurations: [{ configurationValue: 1, configurationName: "ADB", interfaces: [{ interfaceNumber: 0, claimed: true,
      alternate: { alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 0x01,
        endpoints: [{ endpointNumber: 1, direction: "in", type: "bulk", packetSize: 16384 }, { endpointNumber: 2, direction: "out", type: "bulk", packetSize: 16384 }] },
      alternates: [{ alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 0x01,
        endpoints: [{ endpointNumber: 1, direction: "in", type: "bulk", packetSize: 16384 }, { endpointNumber: 2, direction: "out", type: "bulk", packetSize: 16384 }] }]
    }]}],
    get configuration() { return this.configurations[0]; },
    async open() {
      ws = new WebSocket(WS_URL); ws.binaryType = "arraybuffer";
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
      ws.onmessage = (e) => processStream(new Uint8Array(e.data)); this.opened = true;
      console.log("⚡ Emülatör WebSocket bağlantısı açıldı!");
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
      ws.send(u8); return { bytesWritten: u8.byteLength, status: "ok" };
    }
  };
  navigator.usb.requestDevice = async () => fakeUsbDevice;
  navigator.usb.getDevices = async () => [fakeUsbDevice];
  console.log("✅ Emülatör WebUSB Köprüsü Aktif! Şimdi sitedeki butona basabilirsin.");
})();
JSEOF

# 4. Panoya Otomatik Kopyala (Wayland wl-copy veya X11 xclip)
if command -v wl-copy >/dev/null 2>&1; then
    echo "$JS_CODE" | wl-copy
    echo "📋 JS Kodu panoya otomatik kopyalandı! (Tarayıcı F12 Console'da direkt Ctrl+V yap)"
elif command -v xclip >/dev/null 2>&1; then
    echo "$JS_CODE" | xclip -selection clipboard
    echo "📋 JS Kodu panoya otomatik kopyalandı! (Tarayıcı F12 Console'da direkt Ctrl+V yap)"
else
    echo "⚠️ wl-copy bulunamadı, kodu manuel kopyalaman gerekebilir."
fi

# 5. Websockify Başlat
echo "🚀 Websockify başlatılıyor (8080 -> 127.0.0.1:$ADB_PORT)..."
exec websockify 8080 127.0.0.1:$ADB_PORT
EOF

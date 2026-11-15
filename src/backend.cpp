#include "backend.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTime>

Backend::Backend(QObject *parent) : QObject(parent) {
    connect(&m_bridge, &AdbBridge::clientStateChanged, this, [this](bool connected) {
        emit browserConnectedChanged();
        setStatusText(connected ? "Tarayıcı bağlı" : "Tarayıcı bekleniyor");
    });

    connect(&m_bridge, &AdbBridge::logMessage, this, &Backend::appendLog);

    connect(&m_adbProcess, &QProcess::finished, this, [this](int exitCode, QProcess::ExitStatus status) {
        emit scanningChanged();
        if (exitCode != 0 || status != QProcess::NormalExit) {
            appendLog("ADB cihaz taraması başarısız oldu.");
            setStatusText("ADB bulunamadı veya çalışmıyor");
            return;
        }

        const QString out = QString::fromUtf8(m_adbProcess.readAllStandardOutput());
        QStringList found;
        const QStringList lines = out.split('\n', Qt::SkipEmptyParts);
        for (int i = 1; i < lines.size(); ++i) {
            const QStringList parts = lines[i].trimmed().split(QRegularExpression("\\s+"));
            if (parts.size() >= 2 && parts[1] == "device")
                found.append(parts[0]);
        }

        if (found != m_devices) {
            m_devices = found;
            emit devicesChanged();
        }

        if (m_devices.isEmpty()) {
            if (!m_selectedDevice.isEmpty()) {
                m_selectedDevice.clear();
                emit selectedDeviceChanged();
            }
            setStatusText("Bağlı ADB cihazı bulunamadı");
        } else {
            if (!m_devices.contains(m_selectedDevice)) {
                m_selectedDevice = m_devices.first();
                emit selectedDeviceChanged();
            }
            if (!running())
                setStatusText(QString("%1 cihaz hazır").arg(m_devices.size()));
        }
    });

    connect(&m_adbProcess, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        emit scanningChanged();
        appendLog("adb komutu çalıştırılamadı (PATH içinde değil).");
        setStatusText("adb bulunamadı");
    });

    refreshDevices();
}

Backend::~Backend() {
    if (m_adbProcess.state() != QProcess::NotRunning) {
        m_adbProcess.kill();
        m_adbProcess.waitForFinished(500);
    }
}

void Backend::setSelectedDevice(const QString &device) {
    if (m_selectedDevice == device)
        return;
    m_selectedDevice = device;
    emit selectedDeviceChanged();
}

void Backend::setPort(int port) {
    if (port < 1024 || port > 65535 || m_port == port)
        return;
    m_port = port;
    emit portChanged();
}

void Backend::refreshDevices() {
    if (m_adbProcess.state() != QProcess::NotRunning)
        return;

    const QString adb = QStandardPaths::findExecutable("adb");
    if (adb.isEmpty()) {
        appendLog("adb bulunamadı.");
        setStatusText("adb PATH içinde değil");
        return;
    }

    emit scanningChanged();
    m_adbProcess.start(adb, {"devices"});
}

void Backend::toggleBridge() {
    if (running()) {
        m_bridge.stop();
        emit runningChanged();
        emit browserConnectedChanged();
        appendLog("Köprü durduruldu.");
        setStatusText("Durduruldu");
        return;
    }

    if (m_selectedDevice.isEmpty()) {
        appendLog("Önce bir ADB cihazı seçmelisin.");
        setStatusText("Cihaz seçilmedi");
        return;
    }

    QString err;
    if (!m_bridge.start(m_selectedDevice, static_cast<quint16>(m_port), &err)) {
        appendLog("Port açılamadı: " + err);
        setStatusText("Port hatası: " + err);
        return;
    }

    emit runningChanged();
    setStatusText(QString("Dinleniyor (ws://127.0.0.1:%1)").arg(m_port));
}

void Backend::copyJsSnippet() {
    QGuiApplication::clipboard()->setText(buildJsSnippet());
    appendLog("JS köprü kodu panoya kopyalandı (F12 Console'a yapıştır).");
    emit jsCopied();
}

void Backend::clearLogs() {
    if (m_logs.isEmpty())
        return;
    m_logs.clear();
    emit logsChanged();
}

void Backend::appendLog(const QString &line) {
    const QString stamped = QString("[%1] %2").arg(QTime::currentTime().toString("HH:mm:ss"), line);
    m_logs.append(stamped);
    if (m_logs.size() > 200)
        m_logs.removeFirst();
    emit logsChanged();
}

void Backend::setStatusText(const QString &text) {
    if (m_statusText == text)
        return;
    m_statusText = text;
    emit statusChanged();
}

QString Backend::buildJsSnippet() const {
    return QStringLiteral(R"JS((() => {
  const WS_URL = "ws://127.0.0.1:%1";
  let ws = null, rxPackets = [], pendingReads = [];

  function resetState(targetWs) {
    if (targetWs && targetWs !== ws) return;
    if (ws) {
      ws.onclose = null; ws.onerror = null; ws.onmessage = null;
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
      const sock = new WebSocket(WS_URL);
      sock.binaryType = "arraybuffer";
      ws = sock;
      await new Promise((res, rej) => { sock.onopen = res; sock.onerror = rej; });
      sock.onmessage = (e) => enqueueUsbPacket(new Uint8Array(e.data));
      sock.onclose = () => resetState(sock);
      this.opened = true;
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
      if (ws && ws.readyState === 1) ws.send(u8);
      return { bytesWritten: u8.byteLength, status: "ok" };
    }
  };

  Object.defineProperty(navigator.usb, "requestDevice", { value: async () => fakeUsbDevice, configurable: true, writable: true });
  Object.defineProperty(navigator.usb, "getDevices", { value: async () => [fakeUsbDevice], configurable: true, writable: true });
  console.log("✅ [Universal Bridge] Aktif! Şimdi sitedeki Install / Cihaz Seç butonuna basabilirsin.");
})();)JS").arg(m_port);
}

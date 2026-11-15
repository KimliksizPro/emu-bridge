#include "adbbridge.h"

#include <QCryptographicHash>
#include <QHostAddress>
#include <QtEndian>

namespace {
constexpr quint32 kMaxChunkSize = 15360; // Avoids 16384-byte USB ZLP stalls.
constexpr quint64 kMaxWsPayload = 64ULL * 1024ULL * 1024ULL;

QByteArray adbLengthPrefix(int len) {
    return QByteArray::number(len, 16).rightJustified(4, '0');
}

void writeU32LE(QByteArray &buf, int offset, quint32 val) {
    qToLittleEndian(val, reinterpret_cast<uchar *>(buf.data() + offset));
}

quint32 readU32LE(const QByteArray &buf, int offset) {
    return qFromLittleEndian<quint32>(reinterpret_cast<const uchar *>(buf.constData() + offset));
}
} // namespace

AdbBridge::AdbBridge(QObject *parent) : QObject(parent) {
    connect(&m_server, &QTcpServer::newConnection, this, &AdbBridge::onNewConnection);
}

AdbBridge::~AdbBridge() {
    stop();
}

bool AdbBridge::start(const QString &serial, quint16 port, QString *errorOut) {
    stop();
    m_serial = serial;
    if (!m_server.listen(QHostAddress::LocalHost, port)) {
        if (errorOut)
            *errorOut = m_server.errorString();
        return false;
    }
    emit logMessage(QString("Köprü hazır: ws://127.0.0.1:%1 -> %2").arg(port).arg(serial));
    return true;
}

void AdbBridge::stop() {
    closeAllStreams();
    if (m_client) {
        m_client->disconnect(this);
        m_client->abort();
        m_client->deleteLater();
        m_client = nullptr;
    }
    if (m_wsUpgraded) {
        m_wsUpgraded = false;
        emit clientStateChanged(false);
    }
    m_httpBuf.clear();
    m_wsBuf.clear();
    m_adbRxBuf.clear();
    if (m_server.isListening())
        m_server.close();
}

void AdbBridge::onNewConnection() {
    while (m_server.hasPendingConnections()) {
        QTcpSocket *sock = m_server.nextPendingConnection();
        if (m_client) {
            m_client->disconnect(this);
            m_client->abort();
            m_client->deleteLater();
            m_client = nullptr;
            closeAllStreams();
            if (m_wsUpgraded) {
                m_wsUpgraded = false;
                emit clientStateChanged(false);
            }
        }
        m_client = sock;
        m_wsUpgraded = false;
        m_httpBuf.clear();
        m_wsBuf.clear();
        m_adbRxBuf.clear();
        connect(m_client, &QTcpSocket::readyRead, this, &AdbBridge::onClientReadyRead);
        connect(m_client, &QTcpSocket::disconnected, this, &AdbBridge::onClientDisconnected);
    }
}

void AdbBridge::onClientReadyRead() {
    if (!m_client)
        return;
    if (!m_wsUpgraded) {
        m_httpBuf.append(m_client->readAll());
        handleHttpUpgrade();
    } else {
        m_wsBuf.append(m_client->readAll());
        parseWebSocketFrames();
    }
}

void AdbBridge::onClientDisconnected() {
    closeAllStreams();
    if (m_client) {
        m_client->deleteLater();
        m_client = nullptr;
    }
    if (m_wsUpgraded) {
        m_wsUpgraded = false;
        emit clientStateChanged(false);
        emit logMessage("Tarayıcı bağlantısı kapandı.");
    }
}

void AdbBridge::handleHttpUpgrade() {
    const int headerEnd = m_httpBuf.indexOf("\r\n\r\n");
    if (headerEnd < 0)
        return;

    const QByteArray req = m_httpBuf.left(headerEnd);
    m_httpBuf.remove(0, headerEnd + 4);

    QByteArray key;
    for (const QByteArray &line : req.split('\n')) {
        const QByteArray trimmed = line.trimmed();
        if (trimmed.toLower().startsWith("sec-websocket-key:")) {
            key = trimmed.mid(18).trimmed();
            break;
        }
    }

    if (key.isEmpty()) {
        m_client->write("HTTP/1.1 200 OK\r\nContent-Length: 18\r\n\r\nADB Bridge Running");
        m_client->disconnectFromHost();
        return;
    }

    const QByteArray accept = QCryptographicHash::hash(
        key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", QCryptographicHash::Sha1).toBase64();

    const QByteArray response =
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Accept: " + accept + "\r\n\r\n";

    m_client->write(response);
    m_wsUpgraded = true;
    emit clientStateChanged(true);
    emit logMessage("Tarayıcı bağlandı (WebSocket aktif).");

    if (!m_httpBuf.isEmpty()) {
        m_wsBuf.append(m_httpBuf);
        m_httpBuf.clear();
        parseWebSocketFrames();
    }
}

void AdbBridge::parseWebSocketFrames() {
    while (m_wsBuf.size() >= 2) {
        const quint8 b0 = static_cast<quint8>(m_wsBuf[0]);
        const quint8 b1 = static_cast<quint8>(m_wsBuf[1]);
        const quint8 opcode = b0 & 0x0f;
        const bool masked = (b1 & 0x80) != 0;
        quint64 payloadLen = b1 & 0x7f;
        int offset = 2;

        if (payloadLen == 126) {
            if (m_wsBuf.size() < 4)
                return;
            payloadLen = qFromBigEndian<quint16>(reinterpret_cast<const uchar *>(m_wsBuf.constData() + 2));
            offset = 4;
        } else if (payloadLen == 127) {
            if (m_wsBuf.size() < 10)
                return;
            payloadLen = qFromBigEndian<quint64>(reinterpret_cast<const uchar *>(m_wsBuf.constData() + 2));
            offset = 10;
        }

        if (payloadLen > kMaxWsPayload) {
            if (m_client)
                m_client->abort();
            return;
        }

        const int maskOffset = offset;
        if (masked)
            offset += 4;
        if (static_cast<quint64>(m_wsBuf.size()) < static_cast<quint64>(offset) + payloadLen)
            return;

        QByteArray payload = m_wsBuf.mid(offset, static_cast<int>(payloadLen));
        if (masked) {
            for (int i = 0; i < payload.size(); ++i)
                payload[i] = payload[i] ^ m_wsBuf[maskOffset + (i & 3)];
        }
        m_wsBuf.remove(0, offset + static_cast<int>(payloadLen));

        if (opcode == 0x08) {
            if (m_client)
                m_client->disconnectFromHost();
            return;
        }
        if (opcode == 0x09) {
            wsSend(payload, 0x8a);
            continue;
        }
        if (opcode == 0x00 || opcode == 0x01 || opcode == 0x02)
            onWsPayload(payload);
    }
}

void AdbBridge::onWsPayload(const QByteArray &data) {
    m_adbRxBuf.append(data);
    while (m_adbRxBuf.size() >= 24) {
        const quint32 len = readU32LE(m_adbRxBuf, 12);
        if (static_cast<quint64>(m_adbRxBuf.size()) < 24ULL + len)
            break;
        const QByteArray cmd = m_adbRxBuf.left(4);
        const quint32 arg0 = readU32LE(m_adbRxBuf, 4);
        const quint32 arg1 = readU32LE(m_adbRxBuf, 8);
        const QByteArray payload = m_adbRxBuf.mid(24, static_cast<int>(len));
        m_adbRxBuf.remove(0, 24 + static_cast<int>(len));
        handleAdbCommand(cmd, arg0, arg1, payload);
    }
}

void AdbBridge::handleAdbCommand(const QByteArray &cmd, quint32 arg0, quint32 arg1, const QByteArray &payload) {
    if (cmd == "CNXN") {
        emit logMessage("CNXN alındı -> Cihaz bağlantısı onaylandı.");
        sendAdbPacket("CNXN", 0x01000000, 256 * 1024, QByteArray("device::ro.product.name=bridge;\0", 32));
        return;
    }

    if (cmd == "OPEN") {
        const quint32 localId = arg0;
        const quint32 remoteId = localId + 1000;
        QByteArray svcBuf = payload;
        if (!svcBuf.isEmpty() && svcBuf.back() == '\0')
            svcBuf.chop(1);

        if (Stream *existing = m_streams.value(localId, nullptr))
            closeStream(existing, false);

        emit logMessage(QString("Kanal açılıyor [%1]: %2").arg(localId).arg(QString::fromUtf8(svcBuf)));

        auto *st = new Stream();
        st->sock = new QTcpSocket(this);
        st->localId = localId;
        st->remoteId = remoteId;
        m_streams.insert(localId, st);

        connect(st->sock, &QTcpSocket::connected, this, [this, st]() {
            if (st->closed)
                return;
            const QByteArray tp = ("host:transport:" + m_serial).toUtf8();
            st->sock->write(adbLengthPrefix(tp.size()) + tp);
        });

        connect(st->sock, &QTcpSocket::readyRead, this, [this, st, svcBuf]() {
            if (st->closed)
                return;
            const QByteArray chunk = st->sock->readAll();
            if (st->step < 2) {
                st->statusBuf.append(chunk);
                while (st->step < 2 && st->statusBuf.size() >= 4) {
                    const QByteArray status = st->statusBuf.left(4);
                    st->statusBuf.remove(0, 4);
                    if (status == "OKAY") {
                        st->step++;
                        if (st->step == 1) {
                            st->sock->write(adbLengthPrefix(svcBuf.size()) + svcBuf);
                        } else if (st->step == 2) {
                            sendAdbPacket("OKAY", st->remoteId, st->localId);
                            if (!st->statusBuf.isEmpty()) {
                                enqueueStreamData(st, st->statusBuf);
                                st->statusBuf.clear();
                            }
                        }
                    } else {
                        closeStream(st, true, 0);
                        return;
                    }
                }
            } else {
                enqueueStreamData(st, chunk);
            }
        });

        connect(st->sock, &QTcpSocket::disconnected, this, [this, st]() {
            if (st->closed)
                return;
            if (st->step >= 2) {
                st->eof = true;
                flushStream(st);
            } else {
                closeStream(st, true, 0);
            }
        });

        connect(st->sock, &QTcpSocket::errorOccurred, this, [this, st](QAbstractSocket::SocketError err) {
            if (st->closed || err == QAbstractSocket::RemoteHostClosedError)
                return;
            closeStream(st, true, st->step >= 2 ? st->remoteId : 0);
        });

        st->sock->connectToHost(QHostAddress::LocalHost, 5037);
        return;
    }

    if (cmd == "WRTE") {
        if (Stream *st = findStream(arg0, arg1); st && !st->closed && st->step >= 2) {
            st->sock->write(payload);
            sendAdbPacket("OKAY", st->remoteId, st->localId);
        }
        return;
    }

    if (cmd == "OKAY") {
        if (Stream *st = findStream(arg0, arg1); st && !st->closed) {
            st->waitingOkay = false;
            flushStream(st);
        }
        return;
    }

    if (cmd == "CLSE") {
        if (Stream *st = findStream(arg0, arg1); st && !st->closed)
            closeStream(st, true, st->remoteId);
    }
}

void AdbBridge::wsSend(const QByteArray &payload, quint8 opcode) {
    if (!m_client || m_client->state() != QAbstractSocket::ConnectedState)
        return;

    const quint64 len = static_cast<quint64>(payload.size());
    QByteArray header;
    if (len < 126) {
        header.resize(2);
        header[0] = static_cast<char>(opcode);
        header[1] = static_cast<char>(len);
    } else if (len < 65536) {
        header.resize(4);
        header[0] = static_cast<char>(opcode);
        header[1] = 126;
        qToBigEndian(static_cast<quint16>(len), reinterpret_cast<uchar *>(header.data() + 2));
    } else {
        header.resize(10);
        header[0] = static_cast<char>(opcode);
        header[1] = 127;
        qToBigEndian(len, reinterpret_cast<uchar *>(header.data() + 2));
    }
    m_client->write(header + payload);
}

void AdbBridge::sendAdbPacket(const char *cmd, quint32 arg0, quint32 arg1, const QByteArray &payload) {
    QByteArray header(24, '\0');
    memcpy(header.data(), cmd, 4);
    writeU32LE(header, 4, arg0);
    writeU32LE(header, 8, arg1);
    writeU32LE(header, 12, static_cast<quint32>(payload.size()));

    quint32 sum = 0;
    for (uchar b : payload)
        sum += b;
    writeU32LE(header, 16, sum);

    const quint32 cmdInt = readU32LE(header, 0);
    writeU32LE(header, 20, ~cmdInt);

    wsSend(header);
    if (!payload.isEmpty())
        wsSend(payload);
}

void AdbBridge::enqueueStreamData(Stream *st, const QByteArray &data) {
    for (int i = 0; i < data.size(); i += kMaxChunkSize)
        st->txQueue.enqueue(data.mid(i, kMaxChunkSize));
    flushStream(st);
}

void AdbBridge::flushStream(Stream *st) {
    if (st->closed || st->waitingOkay)
        return;
    if (!st->txQueue.isEmpty()) {
        const QByteArray chunk = st->txQueue.dequeue();
        st->waitingOkay = true;
        sendAdbPacket("WRTE", st->remoteId, st->localId, chunk);
    } else if (st->eof) {
        closeStream(st, true, st->remoteId);
    }
}

AdbBridge::Stream *AdbBridge::findStream(quint32 arg0, quint32 arg1) {
    if (m_streams.contains(arg0))
        return m_streams.value(arg0);
    if (arg1 >= 1000)
        return m_streams.value(arg1 - 1000, nullptr);
    return nullptr;
}

void AdbBridge::closeStream(Stream *st, bool sendClse, quint32 clseRemoteId) {
    if (!st || st->closed)
        return;
    st->closed = true;
    m_streams.remove(st->localId);
    if (st->sock) {
        st->sock->disconnect(this);
        st->sock->abort();
        st->sock->deleteLater();
        st->sock = nullptr;
    }
    if (sendClse)
        sendAdbPacket("CLSE", clseRemoteId, st->localId);
    delete st;
}

void AdbBridge::closeAllStreams() {
    const auto all = m_streams.values();
    m_streams.clear();
    for (Stream *st : all) {
        st->closed = true;
        if (st->sock) {
            st->sock->disconnect(this);
            st->sock->abort();
            st->sock->deleteLater();
            st->sock = nullptr;
        }
        delete st;
    }
}

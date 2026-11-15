#pragma once

#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QQueue>
#include <QTcpServer>
#include <QTcpSocket>

// Native WebSocket-to-ADB (127.0.0.1:5037) bridge replacing the Node.js process.
class AdbBridge : public QObject {
    Q_OBJECT

public:
    explicit AdbBridge(QObject *parent = nullptr);
    ~AdbBridge() override;

    bool start(const QString &serial, quint16 port, QString *errorOut = nullptr);
    void stop();
    bool isRunning() const { return m_server.isListening(); }
    bool hasClient() const { return m_client != nullptr && m_wsUpgraded; }

signals:
    void clientStateChanged(bool connected);
    void logMessage(const QString &message);

private slots:
    void onNewConnection();
    void onClientReadyRead();
    void onClientDisconnected();

private:
    struct Stream {
        QTcpSocket *sock = nullptr;
        quint32 localId = 0;
        quint32 remoteId = 0;
        int step = 0;
        QByteArray statusBuf;
        QQueue<QByteArray> txQueue;
        bool waitingOkay = false;
        bool eof = false;
        bool closed = false;
    };

    void handleHttpUpgrade();
    void parseWebSocketFrames();
    void onWsPayload(const QByteArray &data);
    void handleAdbCommand(const QByteArray &cmd, quint32 arg0, quint32 arg1, const QByteArray &payload);
    void wsSend(const QByteArray &payload, quint8 opcode = 0x82);
    void sendAdbPacket(const char *cmd, quint32 arg0, quint32 arg1, const QByteArray &payload = {});
    void enqueueStreamData(Stream *st, const QByteArray &data);
    void flushStream(Stream *st);
    Stream *findStream(quint32 arg0, quint32 arg1);
    void closeAllStreams();

    QTcpServer m_server;
    QTcpSocket *m_client = nullptr;
    QString m_serial;
    bool m_wsUpgraded = false;
    QByteArray m_httpBuf;
    QByteArray m_wsBuf;
    QByteArray m_adbRxBuf;
    QHash<quint32, Stream *> m_streams;
};

#pragma once

#include <QObject>
#include <QProcess>
#include <QStringList>

#include "adbbridge.h"

class Backend : public QObject {
    Q_OBJECT
    Q_PROPERTY(QStringList devices READ devices NOTIFY devicesChanged)
    Q_PROPERTY(QString selectedDevice READ selectedDevice WRITE setSelectedDevice NOTIFY selectedDeviceChanged)
    Q_PROPERTY(int port READ port WRITE setPort NOTIFY portChanged)
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(bool browserConnected READ browserConnected NOTIFY browserConnectedChanged)
    Q_PROPERTY(bool scanning READ scanning NOTIFY scanningChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(QStringList logs READ logs NOTIFY logsChanged)

public:
    explicit Backend(QObject *parent = nullptr);
    ~Backend() override;

    QStringList devices() const { return m_devices; }
    QString selectedDevice() const { return m_selectedDevice; }
    void setSelectedDevice(const QString &device);

    int port() const { return m_port; }
    void setPort(int port);

    bool running() const { return m_bridge.isRunning(); }
    bool browserConnected() const { return m_bridge.hasClient(); }
    bool scanning() const { return m_adbProcess.state() != QProcess::NotRunning; }
    QString statusText() const { return m_statusText; }
    QStringList logs() const { return m_logs; }

    Q_INVOKABLE void refreshDevices();
    Q_INVOKABLE void toggleBridge();
    Q_INVOKABLE void copyJsSnippet();
    Q_INVOKABLE void clearLogs();

signals:
    void devicesChanged();
    void selectedDeviceChanged();
    void portChanged();
    void runningChanged();
    void browserConnectedChanged();
    void scanningChanged();
    void statusChanged();
    void logsChanged();
    void jsCopied();

private:
    void appendLog(const QString &line);
    void setStatusText(const QString &text);
    QString buildJsSnippet() const;

    AdbBridge m_bridge;
    QProcess m_adbProcess;
    QStringList m_devices;
    QString m_selectedDevice;
    int m_port = 8080;
    QString m_statusText = "Hazır";
    QStringList m_logs;
};

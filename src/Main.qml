import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

ApplicationWindow {
    id: root
    width: 440
    height: 490
    minimumWidth: 380
    minimumHeight: 400
    visible: true
    title: "ADB WebUSB Bridge"

    property bool darkMode: true
    property bool copiedFeedback: false
    property bool editingPort: false

    // Strict Red / White / Black minimal palette
    readonly property color redMain: darkMode ? "#ef233c" : "#d90429"
    readonly property color redHover: darkMode ? "#ff3b52" : "#ef233c"

    readonly property color bgWindow: darkMode ? "#0a0a0a" : "#f6f6f6"
    readonly property color bgCard: darkMode ? "#121212" : "#ffffff"
    readonly property color bgRecessed: darkMode ? "#0e0e0e" : "#fafafa"
    readonly property color bgPill: darkMode ? "#1a1a1a" : "#efefef"
    readonly property color bgPillHover: darkMode ? "#242424" : "#e2e2e2"
    readonly property color borderSubtle: darkMode ? "#222222" : "#e5e5e5"
    readonly property color borderControl: darkMode ? "#2e2e2e" : "#d4d4d4"
    readonly property color textPrimary: darkMode ? "#ffffff" : "#0a0a0a"
    readonly property color textSecondary: darkMode ? "#b5b5b5" : "#404040"
    readonly property color textMuted: darkMode ? "#737373" : "#737373"

    color: bgWindow
    Behavior on color { ColorAnimation { duration: 150 } }

    Material.theme: darkMode ? Material.Dark : Material.Light
    Material.accent: redMain

    Timer {
        id: copyTimer
        interval: 1500
        onTriggered: root.copiedFeedback = false
    }

    function commitPort() {
        const val = parseInt(portInput.text)
        if (!isNaN(val) && val >= 1024 && val <= 65535)
            backend.port = val
        portInput.text = backend.port.toString()
        portInput.focus = false
    }

    Connections {
        target: backend
        function onJsCopied() {
            root.copiedFeedback = true
            copyTimer.restart()
        }
        function onLogsChanged() {
            Qt.callLater(logView.positionViewAtEnd)
        }
    }

    Shortcut {
        sequence: "Space"
        context: Qt.ApplicationShortcut
        enabled: !portInput.activeFocus
        onActivated: backend.toggleBridge()
    }
    Shortcut {
        sequence: "R"
        context: Qt.ApplicationShortcut
        enabled: !portInput.activeFocus
        onActivated: backend.refreshDevices()
    }
    Shortcut {
        sequence: "C"
        context: Qt.ApplicationShortcut
        enabled: !portInput.activeFocus
        onActivated: backend.copyJsSnippet()
    }
    Shortcut {
        sequence: "T"
        context: Qt.ApplicationShortcut
        enabled: !portInput.activeFocus
        onActivated: root.darkMode = !root.darkMode
    }
    Shortcut {
        sequence: "Q"
        context: Qt.ApplicationShortcut
        enabled: !portInput.activeFocus
        onActivated: Qt.quit()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        // Minimal Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Rectangle {
                id: statusDot
                visible: backend.running
                width: 8
                height: 8
                radius: 4
                color: root.redMain

                SequentialAnimation on opacity {
                    running: backend.running && !backend.browserConnected
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) statusDot.opacity = 1.0
                    NumberAnimation { to: 0.25; duration: 650; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutQuad }
                }
            }

            Label {
                text: "ADB Bridge"
                font.pixelSize: 18
                font.weight: Font.Bold
                color: root.textPrimary
                Layout.fillWidth: true
            }

            // Inline Port Pill
            Rectangle {
                radius: 14
                color: root.bgPill
                border.color: root.editingPort ? root.redMain : root.borderControl
                border.width: 1
                implicitHeight: 28
                implicitWidth: portRow.implicitWidth + 18
                opacity: backend.running ? 0.5 : 1.0

                RowLayout {
                    id: portRow
                    anchors.centerIn: parent
                    spacing: 4

                    Label {
                        text: ":"
                        font.family: "monospace"
                        font.pixelSize: 12
                        color: root.textMuted
                    }

                    TextInput {
                        id: portInput
                        text: backend.port.toString()
                        enabled: !backend.running
                        color: root.textPrimary
                        font.family: "monospace"
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        selectByMouse: true
                        validator: IntValidator { bottom: 1024; top: 65535 }
                        Layout.preferredWidth: Math.max(34, contentWidth + 2)
                        onActiveFocusChanged: {
                            root.editingPort = activeFocus
                            if (!activeFocus)
                                root.commitPort()
                        }
                        onEditingFinished: root.commitPort()
                    }
                }
            }

            // Refresh Pill
            Rectangle {
                radius: 14
                color: refreshMouse.containsMouse && !backend.running ? root.bgPillHover : root.bgPill
                border.color: root.borderControl
                border.width: 1
                implicitHeight: 28
                implicitWidth: 28
                opacity: (backend.running || backend.scanning) ? 0.45 : 1.0

                Label {
                    anchors.centerIn: parent
                    text: "↻"
                    font.pixelSize: 14
                    color: root.textPrimary
                }

                MouseArea {
                    id: refreshMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !backend.running && !backend.scanning
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: backend.refreshDevices()
                }
            }

            // Theme Toggle Pill
            Rectangle {
                width: 28
                height: 28
                radius: 14
                color: themeMouse.containsMouse ? root.bgPillHover : root.bgPill
                border.color: root.borderControl
                border.width: 1

                Label {
                    anchors.centerIn: parent
                    text: root.darkMode ? "☀" : "☾"
                    font.pixelSize: 13
                    color: root.textPrimary
                }

                MouseArea {
                    id: themeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.darkMode = !root.darkMode
                }
            }
        }

        // Device List (only border turns red when selected)
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 8

            Repeater {
                model: backend.devices

                Rectangle {
                    required property string modelData
                    readonly property bool isSelected: backend.selectedDevice === modelData

                    Layout.fillWidth: true
                    height: 44
                    radius: 12
                    color: devMouse.containsMouse && !backend.running ? root.bgPillHover : root.bgCard
                    border.color: isSelected ? root.redMain : root.borderSubtle
                    border.width: isSelected ? 1.5 : 1
                    opacity: backend.running && !isSelected ? 0.45 : 1.0

                    Behavior on border.color { ColorAnimation { duration: 120 } }
                    Behavior on color { ColorAnimation { duration: 120 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14

                        Label {
                            text: modelData
                            font.family: "monospace"
                            font.pixelSize: 12
                            font.weight: isSelected ? Font.DemiBold : Font.Normal
                            color: root.textPrimary
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: devMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !backend.running
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: backend.selectedDevice = modelData
                    }
                }
            }

            Rectangle {
                visible: backend.devices.length === 0
                Layout.fillWidth: true
                height: 44
                radius: 12
                color: root.bgCard
                border.color: root.borderSubtle
                border.width: 1

                Label {
                    anchors.centerIn: parent
                    text: "Cihaz bulunamadı"
                    font.pixelSize: 12
                    color: root.textMuted
                }
            }
        }

        // Modern Rounded Action Buttons
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Rectangle {
                id: startBtn
                Layout.fillWidth: true
                height: 46
                radius: 23
                readonly property bool canStart: backend.running || backend.selectedDevice.length > 0
                color: {
                    if (!canStart) return root.bgPill
                    if (backend.running) return startMouse.containsMouse ? root.bgPillHover : root.bgCard
                    return startMouse.containsMouse ? root.redHover : root.redMain
                }
                border.color: backend.running ? root.redMain : (canStart ? root.redMain : root.borderControl)
                border.width: backend.running ? 1.5 : 1
                opacity: canStart ? 1.0 : 0.45
                scale: startMouse.pressed ? 0.98 : 1.0

                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on scale { NumberAnimation { duration: 80 } }

                Label {
                    anchors.centerIn: parent
                    text: backend.running ? "Durdur" : "Başlat"
                    font.pixelSize: 13
                    font.weight: Font.Bold
                    color: backend.running ? root.redMain : (startBtn.canStart ? "#ffffff" : root.textMuted)
                }

                MouseArea {
                    id: startMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: startBtn.canStart
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        root.commitPort()
                        backend.toggleBridge()
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: 150
                height: 46
                radius: 23
                color: root.copiedFeedback ? root.redMain : (copyMouse.containsMouse ? root.bgPillHover : root.bgCard)
                border.color: root.copiedFeedback ? root.redMain : root.borderControl
                border.width: 1
                scale: copyMouse.pressed ? 0.98 : 1.0

                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on scale { NumberAnimation { duration: 80 } }

                Label {
                    anchors.centerIn: parent
                    text: root.copiedFeedback ? "Kopyalandı ✓" : "JS Kopyala"
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    color: root.copiedFeedback ? "#ffffff" : root.textPrimary
                }

                MouseArea {
                    id: copyMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: backend.copyJsSnippet()
                }
            }
        }

        // Minimal Logs Box
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: root.bgCard
            border.color: root.borderSubtle
            border.width: 1
            radius: 14

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true

                    Label {
                        text: "Loglar"
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        color: root.textMuted
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        visible: logView.count > 0
                        radius: 10
                        color: clearMouse.containsMouse ? root.bgPillHover : "transparent"
                        implicitHeight: 22
                        implicitWidth: clearLbl.implicitWidth + 14

                        Label {
                            id: clearLbl
                            anchors.centerIn: parent
                            text: "Temizle"
                            font.pixelSize: 11
                            color: root.redMain
                        }

                        MouseArea {
                            id: clearMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: backend.clearLogs()
                        }
                    }
                }

                ListView {
                    id: logView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: backend.logs
                    spacing: 6

                    delegate: RowLayout {
                        required property string modelData
                        width: logView.width
                        spacing: 8

                        readonly property int splitIdx: modelData.indexOf("] ")
                        readonly property string stamp: splitIdx > 0 ? modelData.slice(1, splitIdx) : ""
                        readonly property string msg: splitIdx > 0 ? modelData.slice(splitIdx + 2) : modelData
                        readonly property bool isImportant: msg.indexOf("bağlandı") >= 0
                                                            || msg.indexOf("onaylandı") >= 0
                                                            || msg.indexOf("hata") >= 0
                                                            || msg.indexOf("bulunamadı") >= 0
                                                            || msg.indexOf("açılamadı") >= 0

                        Label {
                            visible: stamp.length > 0
                            text: stamp
                            font.family: "monospace"
                            font.pixelSize: 11
                            color: root.textMuted
                            Layout.alignment: Qt.AlignTop
                        }

                        Label {
                            text: msg
                            font.family: "monospace"
                            font.pixelSize: 11
                            color: isImportant ? root.redMain : root.textSecondary
                            wrapMode: Text.WrapAnywhere
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }
    }
}

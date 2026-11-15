QT += core gui qml quick quickcontrols2 network

CONFIG += c++17 release
TARGET = emu-bridge
TEMPLATE = app

HEADERS += \
    src/adbbridge.h \
    src/backend.h

SOURCES += \
    src/adbbridge.cpp \
    src/backend.cpp \
    src/main.cpp

RESOURCES += src/resources.qrc

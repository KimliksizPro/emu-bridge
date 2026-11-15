QT += core gui qml quick quickcontrols2 network

CONFIG += c++17 release
TARGET = emu-bridge
TEMPLATE = app

HEADERS += \
    src/adbbridge.h \
    src/backend.h \
    src/theme.h

SOURCES += \
    src/adbbridge.cpp \
    src/backend.cpp \
    src/main.cpp \
    src/theme.cpp

RESOURCES += src/resources.qrc

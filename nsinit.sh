#!/bin/bash

# Прерывать работу при любой ошибке (безопасный режим)
set -e

# Самопривязка монтирования на случай, если при модификации кода
# MERGED_DIR окажется не точкой монтирования, а обычным каталогом, 
# тогда pivot_root не сработает или сработает, но последующий umount -l /old_root убьет систему
mount --bind "$MERGED_DIR" "$MERGED_DIR"
# Рокировка корней
pivot_root "$MERGED_DIR" "$MERGED_DIR/old_root"
cd /
mount --make-rprivate /

# Монтирование ФС ядра
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run

# Назначение имени узла
[ -z "$CONTAINER_NAME" ] && CONTAINER_NAME="nsbox"
hostname "$CONTAINER_NAME"
echo "127.0.0.1 localhost $CONTAINER_NAME" > /etc/hosts

# Проброс пользовательских каталогов (Volumes)
if [ -n "$VOLUME_MAP" ]; then
    mkdir -p "$GUEST_PATH"
    mount --bind "/old_root/$HOST_PATH" "$GUEST_PATH"
fi

if [ "$IS_GUI_ENABLED" = true ]; then
    # Сквозной проброс unix-сокета дисплея из старого корня хоста
    if [ -d /old_root/tmp/.X11-unix ]; then
        mkdir -p /tmp/.X11-unix
        mount --bind /old_root/tmp/.X11-unix /tmp/.X11-unix
    fi

    # Генерация бинарных мандатов аторизации
    if [ -n "$XBOX_HEX_COOKIE" ]; then
        # Обнуление файла авторизации сессии X11
        > /root/.Xauthority
        # Привязка секретной куки хоста ко всем легитимным сокетам и адресам контейнера
        xauth -f /root/.Xauthority add "$CONTAINER_NAME/unix$DISPLAY" MIT-MAGIC-COOKIE-1 "$XBOX_HEX_COOKIE" 2>/dev/null || true
        xauth -f /root/.Xauthority add "localhost$DISPLAY" MIT-MAGIC-COOKIE-1 "$XBOX_HEX_COOKIE" 2>/dev/null || true
        xauth -f /root/.Xauthority add "127.0.0.1$DISPLAY" MIT-MAGIC-COOKIE-1 "$XBOX_HEX_COOKIE" 2>/dev/null || true
    fi
fi

# Размонтирование старого корня хоста
umount -l /old_root
rmdir /old_root

ip link set lo up

if [ "$IS_NET_ENABLED" = true ]; then
    echo "Активация сетевого интерфейса контейнера..."
    
    # Включение проброшенного виртуального кабеля
    ip link set veth-guest up
    
    # Фолбэк для маски подсети (если переменная пуста, откатываемся на /24)
    [ -z "$BRIDGE_MASK" ] && BRIDGE_MASK="24"

    # Присваиваение ip-адреса и актуальной маской хоста
    ip addr add "$GUEST_IP/$BRIDGE_MASK" dev veth-guest
    
    # Маршрут по умолчанию через переданный BRIDGE_IP
    [ -z "$BRIDGE_IP" ] && BRIDGE_IP="10.0.0.1"
    ip route add default via "$BRIDGE_IP"
    
    echo "Сетевой стек контейнера успешно активирован, IP: $GUEST_IP/$BRIDGE_MASK"
fi

# Запуск bash, если COMMAND не определена
COMMAND="${COMMAND:-bash}"

# Стерилизация переменных окружения (env -i) и запуск $COMMAND
exec env -i bash -c "
    export HOME=/root
    export TERM='$TERM'
    export LANG=C.UTF-8
    export LC_CTYPE=C.UTF-8
    export LC_ALL=C.UTF-8
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    if [ '$IS_GUI_ENABLED' = true ]; then
        export DISPLAY='$DISPLAY'
        mkdir -p /run/user/0
        export XDG_RUNTIME_DIR=/run/user/0
        export NO_AT_BRIDGE=1
        export XAUTHORITY=/root/.Xauthority
        # export DBUS_SESSION_BUS_ADDRESS
        exec dbus-run-session -- $COMMAND
    else
        exec $COMMAND
    fi
"

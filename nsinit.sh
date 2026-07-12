#!/bin/bash
set -e

# 1. Внутренние легитимные монтирования слоев оверлея
mount --bind "$MERGED_DIR" "$MERGED_DIR"
pivot_root "$MERGED_DIR" "$MERGED_DIR/old_root"
cd /
mount --make-rprivate /

# Проброс графических сокетов хоста
if [ "$IS_GUI_ENABLED" = true ]; then
    mount --bind /old_root/tmp/.X11-unix /tmp/.X11-unix
    if [ -n "$WAYLAND_DISPLAY" ]; then
        mount --bind "/old_root$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
    fi
fi

# 3. Проброс пользовательских папок (Volumes)
if [ -n "$VOLUME_MAP" ]; then
    mkdir -p "$GUEST_PATH"
    mount --bind "/old_root/$HOST_PATH" "$GUEST_PATH"
fi

# 4. Монтирование виртуальных системных ФС ядра
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run

# 5. Отрезаем старый корень хоста и поднимаем локальную петлю
umount -l /old_root
ip link set lo up

if [ "$IS_NET_ENABLED" = true ]; then
    echo "[nsinit] Нативно активирую сетевой интерфейс..."
    
    # 1. Сначала будим и включаем сам прилетевший veth-кабель
    ip link set veth-guest up
    
    # 2. Нативно вешаем IP-адрес (с прошлого шага)
    ip addr add "$GUEST_IP/24" dev veth-guest
    
    # 3. Прописываем маршрут по умолчанию (с прошлого шага)
    ip route add default via 10.0.0.1
    
    echo "[nsinit] Сетевой стек успешно активирован! Гостевой IP: $GUEST_IP"
fi

# 6. Тотальная стерилизация переменных окружения и старт программы
# Ваша любимая двойная кавычка стоит на своем абсолютно законном месте!
exec env -i bash -c "
    export HOME=/root
    export TERM='$TERM'
    export LANG=C.UTF-8
    export LC_CTYPE=C.UTF-8
    export LC_ALL=C.UTF-8
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    if [ '$IS_GUI_ENABLED' = true ]; then
        export DISPLAY='$DISPLAY'
        export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'
        mkdir -p /run/user/0
        export XDG_RUNTIME_DIR=/run/user/0
        export NO_AT_BRIDGE=1
        export XAUTHORITY=/root/.Xauthority
        exec dbus-run-session -- $COMMAND 2>/dev/null
    else
        exec $COMMAND
    fi
"

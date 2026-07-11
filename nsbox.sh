#!/bin/bash
set -e

# Повышение прав до root'а
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

usage() {
    echo "Использование: $0 [ОПЦИИ]"
    echo ""
    echo "Опции:"
    echo " -c, --command 'команда'       Выполнить команду в изолированном контейнере"
    echo " --clean                       Сбросить все прошлые изменения в контейнере"
    echo " -n, --net                     Включить изолированную сеть с доступом в интернет"
    echo " -v, --volume 'хост:контейнер' Пробросить папку хоста внутрь контейнера"
    echo " -h, --help                    Показать эту справку и выйти"
    exit 1
}

# Максимальный размер виртуального диска
MAX_SIZE="8G"
# Определение путей к файлу-контейнеру и каталогам
IMAGE_FILE="/opt/overlay.img"
ROOT_DIR="/run/root"
BASE_DIR="/opt/overlay"
UPPER_DIR="$BASE_DIR/upper"
WORK_DIR="$BASE_DIR/work"
MERGED_DIR="$BASE_DIR/merged"

VOLUME_MAP=""

VETH_HOST="veth-host"
VETH_GUEST="veth-guest"
NET_NAME="container_net"
NET_NS_FILE="/var/run/netns/$NET_NAME"

# Определение сетевой карта хоста с доступом в интернет
HOST_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
CLEAN_UPPER=false
IS_NET_ENABLED=false # Сеть отключена по умолчанию для максимальной безопасности

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--command)
            if [ -n "$2" ]; then
                COMMAND="$2"
                shift 2
            else
                echo "Ошибка: Флаг $1 требует указания команды в кавычках."
                echo ""
                usage
            fi
            ;;
        --clean)
            CLEAN_UPPER=true
            shift 1
            ;;
        -n|--net)
            IS_NET_ENABLED=true
            shift 1
            ;;
        -v|--volume)
            if [ -n "$2" ]; then
                VOLUME_MAP="$2"
                shift 2
            else
                echo "Ошибка: Флаг $1 требует указания путей через двоеточие 'хост:контейнер'."
                exit 1
            fi
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -n "$1" ]; then
                echo "Неизвестный параметр: $1"
                echo ""
                usage
            fi
            ;;
    esac
done

# По умолчанию запускаем bash
COMMAND="${COMMAND:-bash}"

# Динамическое формирование сетевого префикса
if [ "$IS_NET_ENABLED" = true ]; then
    # Подключение готовой сети хоста
    NET_PREFIX="nsenter --net=$NET_NS_FILE"
else
    # Пустая сеть
    NET_PREFIX="unshare --net"
fi

# Подготовка структуры директорий..."
mkdir -p "$ROOT_DIR" "$BASE_DIR"

# Создание виртуального жесткого диска (в разреженном файле)
if [ ! -f "$IMAGE_FILE" ]; then
    echo "Создание разреженного $IMAGE_FILE с максимальным размером $MAX_SIZE..."
    truncate -s "$MAX_SIZE" "$IMAGE_FILE"
    echo "Форматирование $IMAGE_FILE в ext4..."
    mkfs.ext4 -F "$IMAGE_FILE"
fi

# Монтирование виртуального диска в базовый каталог хоста
if ! mountpoint -q "$BASE_DIR"; then
    mount -o loop,user_xattr "$IMAGE_FILE" "$BASE_DIR"
fi

# Очистка предыдущих изменений по флагу --clean
if [ "$CLEAN_UPPER" = true ]; then
    echo "Очистка предыдущих изменений внутри контейнера..."
    rm -rf "$UPPER_DIR" "$WORK_DIR"
fi

mkdir -p "$UPPER_DIR" "$WORK_DIR" "$MERGED_DIR"

# Сборка OverlayFS в MERGED_DIR
if ! mountpoint -q "$ROOT_DIR"; then mount --bind / "$ROOT_DIR"; fi
if ! mountpoint -q "$MERGED_DIR"; then
    mount -t overlay overlay -o lowerdir="$ROOT_DIR",upperdir="$UPPER_DIR",workdir="$WORK_DIR" "$MERGED_DIR"
fi

# Каталог, используемый для старого корня при рокировке корней
mkdir -p "$MERGED_DIR/old_root"

# Запись правил Readline для контейнера для корректной работы с киррилицей
mkdir -p "$MERGED_DIR/etc"
cat << 'EOF' > "$MERGED_DIR/etc/inputrc"
set input-meta on
set output-meta on
set convert-meta off
set meta-flag on
set byte-oriented off
EOF

# Настройка сетевого пространства на хосте
if [ "$IS_NET_ENABLED" = true ]; then
    echo "Настройка сетевой подсистемы..."

    # Очистка старых интерфейсов хоста перед стартом
    if [ -e "$NET_NS_FILE" ]; then ip netns delete "$NET_NAME"; fi
    ip link delete "$VETH_HOST" 2>/dev/null || true
    nft delete table ip container_nat 2>/dev/null || true

    # Включение NAT на хосте через nftables
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    nft add table ip container_nat
    nft add chain ip container_nat postrouting { type nat hook postrouting priority 100 \; }
    nft add rule ip container_nat postrouting oifname "$HOST_IFACE" ip saddr 10.0.0.0/24 masquerade

    # Создание сетевого пространства имен
    ip netns add "$NET_NAME"
    # Прокладка виртуального сетевого кабеля, конец veth-host закрепляется на хосте,
    # конец veth-guest принудительно заталкивается в созданную сеть
    ip link add "$VETH_HOST" type veth peer name "$VETH_GUEST" netns "$NET_NAME"

    # Поднимаем адаптер VETH_HOST на стороне хоста
    ip link set "$VETH_HOST" up
    ip addr add 10.0.0.1/24 dev "$VETH_HOST"

    # Настройка гостевого конца кабеля внутри созданной сети
    ip netns exec "$NET_NAME" ip link set "$VETH_GUEST" up
    ip netns exec "$NET_NAME" ip addr add 10.0.0.2/24 dev "$VETH_GUEST"
    ip netns exec "$NET_NAME" ip route add default via 10.0.0.1

    # Прописываем DNS
    echo "nameserver 8.8.8.8" > "$MERGED_DIR/etc/resolv.conf"
else
    # Запуск контейнера в глухой изоляции
    echo "" > "$MERGED_DIR/etc/resolv.conf"
fi

echo "Включение контроля ресурсов cgroups v2 (512M)..."
CGROUP_PATH="/sys/fs/cgroup/box_container"
mkdir -p "$CGROUP_PATH"
echo "512M" > "$CGROUP_PATH/memory.max"
echo $$ > "$CGROUP_PATH/cgroup.procs"

# Подготовка путей для проброса каталога в контейнер
if [ -n "$VOLUME_MAP" ]; then
    # Проверка наличия двоеточия
    if ! echo "$VOLUME_MAP" | grep -q ":"; then
        echo "Ошибка: Неверный флаг -v. Шаблон: -v /путь_хоста:/путь_контейнера"
        exit 1
    fi

    # Режем строку на два абсолютных пути со слэшами
    HOST_PATH=$(echo "$VOLUME_MAP" | cut -d':' -f1)
    GUEST_PATH=$(echo "$VOLUME_MAP" | cut -d':' -f2)

    # Проверяем, существует ли HOST_PATH на хосте
    if [ ! -d "$HOST_PATH" ]; then
        echo "Ошибка: Каталог на хосте '$HOST_PATH' не существует."
        exit 1
    fi
fi

# Выполняем команду unshare, после чего запускаем команду, записанную в NET_PREFIX,
# после выполнения команды из NET_PREFIX запускаем команду bash (паровозик команд)
unshare --mount --pid --fork --propagation private $NET_PREFIX bash -c "
    mount --bind '$MERGED_DIR' '$MERGED_DIR'
    pivot_root '$MERGED_DIR' '$MERGED_DIR/old_root'
    cd /
    # Изоляция дисков внутри контейнера
    mount --make-rprivate /

    if [ -n '$VOLUME_MAP' ]; then
        mkdir -p '$GUEST_PATH'
        mount --bind '/old_root/$HOST_PATH' '$GUEST_PATH'
    fi
    
    # Монтирование системных ФС в правильном контексте
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devpts devpts /dev/pts
    mount -t tmpfs tmpfs /run
    
    # Размонтирование корня хоста внутри контейнера
    umount -l /old_root
    
    # Активация локальной петлю внутри контейнера
    ip link set lo up

    # Экспорт переменных окружения контейнера
    exec env -i bash -c '
        export HOME=/root
        export TERM=$TERM
        export LANG=C.UTF-8
        export LC_CTYPE=C.UTF-8
        export LC_ALL=C.UTF-8
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        # Запуск финальной команды в чистом окружении
        exec $COMMAND
    '
"

# Удаление точки монтирования из верхнего слоя изменений
if [ -n "$VOLUME_MAP" ] && [ -d "$UPPER_DIR$GUEST_PATH" ]; then
    rmdir "$UPPER_DIR$GUEST_PATH" 2>/dev/null || true
fi

echo "Размонтирование дисков хоста..."
if mountpoint -q "$MERGED_DIR"; then umount -l "$MERGED_DIR"; fi
if mountpoint -q "$ROOT_DIR"; then umount -l "$ROOT_DIR"; fi
if mountpoint -q "$BASE_DIR"; then umount -l "$BASE_DIR" ; fi

if [ "$IS_NET_ENABLED" = true ]; then
    echo "Очистка сетевых ресурсов хоста..."
    if [ -e "$NET_NS_FILE" ]; then ip netns delete "$NET_NAME"; fi
    ip link delete "$VETH_HOST" 2>/dev/null || true
    nft delete table ip container_nat 2>/dev/null || true
fi

# # Удаление созданной группы cgroups v2
if [ -d "/sys/fs/cgroup/box_container" ]; then
    rmdir "/sys/fs/cgroup/box_container" 2>/dev/null || true
fi

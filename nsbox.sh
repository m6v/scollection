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
    echo "  -c, --command 'команда'       Выполнить команду в изолированном контейнере"
    echo "  --clean                       Сбросить все прошлые изменения в контейнере"
    echo "  -n, --net                     Включить изолированную сеть с доступом в интернет"
    echo "  -p, --port 'хост:контейнер'   Пробросить порт контейнера наружу, например, -p 8080:80"
    echo "  -v, --volume 'хост:контейнер' Пробросить папку хоста внутрь контейнера"
    echo "  -m, --memory 'лимит'          Задать лимит оперативной памяти, например, -m 1G или -m 256M"
    echo "  --cpu 'доля'                  Задать лимит ядер CPU, например, --cpu 1 или --cpu 0.5"
    echo "  -g, --gui                     Разрешить запуск графических приложений внутри контейнера"
    echo "  -d, --detach                  Запустить контейнер в фоновом режиме (демон)"
    echo "  -h, --help                    Показать эту справку и выйти"
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

BRIDGE_NAME="nsboxbr"
VETH_HOST="veth-$$"  # Динамическое имя адаптера хоста
VETH_GUEST="veth-guest"
NET_NAME="container_net"
NET_NS_FILE="/var/run/netns/$NET_NAME"

# Определение сетевой карты хоста с доступом в интернет
HOST_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
CLEAN_UPPER=false
IS_NET_ENABLED=false
IS_GUI_ENABLED=false

# Путь к cgroup контейнера
CGROUP_PATH="/sys/fs/cgroup/nsbox"

run_nsbox_container() {
    # Выполняем команду unshare, после чего запускаем команду, записанную в NET_PREFIX,
    # после выполнения команды из NET_PREFIX запускаем команду bash (паровозик команд)
    unshare --mount --pid --fork --propagation private $NET_PREFIX bash -c "
        mount --bind '$MERGED_DIR' '$MERGED_DIR'
        pivot_root '$MERGED_DIR' '$MERGED_DIR/old_root'
        cd /
        awk '{print $4}' /proc/self/stat > /old_root/run/nsbox.pid 2>/dev/null || true
        # Изоляция дисков внутри контейнера
        mount --make-rprivate /

        # Нативно крепим графические кабели хоста прямо в новый корень контейнера
        if [ '$IS_GUI_ENABLED' = true ]; then
            # Монтируем сокет X11
            mount --bind /old_root/tmp/.X11-unix /tmp/.X11-unix
            
            # Монтируем сокет Wayland (если он есть)
            if [ -n '$WAYLAND_DISPLAY' ]; then
                mount --bind '/old_root$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY' '$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY'
            fi
        fi

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

            if [ '$IS_GUI_ENABLED' = true ]; then
                export DISPLAY='$DISPLAY'
                export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'
                # Создаем чременную папку рантайма прямо в изолированном /run контейнера.
                mkdir -p /run/user/0
                export XDG_RUNTIME_DIR=/run/user/0
                export NO_AT_BRIDGE=1
                export XAUTHORITY=/root/.Xauthority
                # Запуск сессионной шины, которая в свою очередь запустит $COMMAND
                exec dbus-run-session -- '$COMMAND'
            else
                exec '$COMMAND'
            fi
        '
    "
}
export -f run_nsbox_container

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
            # Если следующего аргумента нет или это другой флаг (начинается с '-')
            if [[ -z "$2" ]] || [[ "$2" =~ ^- ]]; then
                GUEST_IP="auto" # Включаем чистый автопилот
                shift 1       # Сдвигаем только сам флаг --net
                
            # Если следующий аргумент — это валидный IP-адрес
            elif [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                GUEST_IP="$2"   # Жестко фиксируем статический адрес
                shift 2       # Сдвигаем и флаг, и сам IP-адрес
                
            # Аргумент передан, но это не флаг и не валидный IP (опечатка!)
            else
                echo "Ошибка: Неверный формат IP-адреса для флага --net: '$2'"
                echo "Используйте валидный IP (например, --net 10.0.0.5) или оставьте флаг пустым для автовыбора."
                exit 1
            fi
            ;;
        -p|--port)
            if [ -n "$2" ]; then
                # Проверяем наличие двоеточия, если его нет — падаем!
                if ! echo "$2" | grep -q ":"; then
                    echo "Ошибка: Неверный формат флага --port: '$2'"
                    echo "Используйте шаблон порт_хоста:порт_контейнера (например, -p 8080:80)."
                    exit 1
                fi
                PORT_MAP="$2"
                shift 2
            else
                echo "Ошибка: Флаг $1 требует указания портов."
                exit 1
            fi
            ;;
        -v|--volume)
            if [ -n "$2" ]; then
                # Проверяем наличие двоеточия, если его нет — выдаем ошибку
                if ! echo "$2" | grep -q ":"; then
                    echo "Ошибка: Неверный формат флага --volume: '$2'"
                    echo "Используйте шаблон путь_хоста:путь_контейнера (например, -v /tmp:/data)."
                    exit 1
                fi
                VOLUME_MAP="$2"
                HOST_PATH=$(echo "$VOLUME_MAP" | cut -d':' -f1)
                GUEST_PATH=$(echo "$VOLUME_MAP" | cut -d':' -f2)
                shift 2
            else
                echo "Ошибка: Флаг $1 требует указания путей монтирования."
                exit 1
            fi
            ;;
        -m|--memory)
            if [ -n "$2" ]; then
                if [[ "$2" =~ ^[0-9]+[kKmMgG]$ ]]; then
                    MEM_LIMIT="$2"
                    shift 2
                else
                    echo "Ошибка: Неверный формат лимита памяти: '$2'"
                    echo "Используйте шаблон из цифр и букв K, M, G (например: -m 256M или --memory 1G)."
                    exit 1
                fi
            else
                echo "Ошибка: Флаг $1 требует указания лимита памяти."
                exit 1
            fi
            ;;
        --cpu)
            if [ -n "$2" ]; then
                # Проверяем формат регулярным выражением (целое число или дробь через точку)
                if [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    CPU_LIMIT="$2"
                    shift 2
                else
                    echo "Ошибка: Неверный формат лимита CPU: '$2'"
                    echo "Используйте целые числа или десятичные дроби (например: --cpu 1 или --cpu 0.5)."
                    exit 1
                fi
            else
                echo "Ошибка: Флаг --cpu требует указания лимита ядер."
                exit 1
            fi
            ;;
        -g|--gui)
            IS_GUI_ENABLED=true
            shift 1
            ;;
        -d|--detach)
            echo "Предупреждение: Запуск контейнера в фоновом режиме пока не реализован"
            IS_DETACHED=true
            shift 1
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

# Создание каталога, используемого для старого корня при рокировке корней
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

echo "Очистка базы пользователей контейнера..."
# Создаем каталог etc в верхнем слое
mkdir -p "$UPPER_DIR/etc"
# Фильтрация системных пользователей
awk -F: '$3 < 1000 || $3 == 65534' /etc/passwd > "$UPPER_DIR/etc/passwd"
# Фильтрация системных групп
awk -F: '$3 < 1000 || $3 == 65534' /etc/group > "$UPPER_DIR/etc/group"
chmod 644 "$UPPER_DIR/etc/passwd" "$UPPER_DIR/etc/group"

# Если задан хотя бы один из лимитов (память или процессор) настроить cgroup
if [ -n "$MEM_LIMIT" ] || [ -n "$CPU_LIMIT" ]; then
    echo "Настройка контроля ресурсов cgroups v2..."
    mkdir -p "$CGROUP_PATH"
    echo $$ > "$CGROUP_PATH/cgroup.procs"

    # Применение лимита оперативной памяти, если указан
    if [ -n "$MEM_LIMIT" ]; then
        echo "Лимит оперативной памяти зафиксирован: $MEM_LIMIT"
        echo "$MEM_LIMIT" > "$CGROUP_PATH/memory.max"
    fi

    # Применение лимита процессора, если указан
    if [ -n "$CPU_LIMIT" ]; then
        echo "Лимит ядер CPU зафиксирован: $CPU_LIMIT"
        # Конвертация долей ядер в микросекунды для cgroups v2, путем умножения на 100000
        CPU_QUOTA=$(awk "BEGIN {print int($CPU_LIMIT * 100000)}")
        echo "$CPU_QUOTA 100000" > "$CGROUP_PATH/cpu.max"
    fi
fi

# Настройка сетевого пространства на хосте
if [ "$IS_NET_ENABLED" != true ]; then
    echo "" > "$MERGED_DIR/etc/resolv.conf"
    return 0
fi

if [ "$GUEST_IP" = "10.0.0.1" ]; then
    echo "Ошибка: Адрес $GUEST_IP занят виртуальным мостом хоста (шлюзом)."
    exit 1
fi

echo "Настройка сети через виртуальный мост $BRIDGE_NAME..."
if [ -e "$NET_NS_FILE" ]; then ip netns delete "$NET_NAME"; fi

if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ip link add "$BRIDGE_NAME" type bridge
    ip addr add 10.0.0.1/24 dev "$BRIDGE_NAME"
    ip link set "$BRIDGE_NAME" up

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    nft add table ip nsbox_nat 2>/dev/null || true
    nft add chain ip nsbox_nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null || true
    nft add rule ip nsbox_nat postrouting oifname "$HOST_IFACE" ip saddr 10.0.0.0/24 masquerade 2>/dev/null || true
fi

if [ "$GUEST_IP" = "auto" ]; then
    # Если включен авторежим, циклом от .2 до .254 и ищем первый свободный IP
    for i in {2..254}; do
        # Проверяем, не выдан ли уже этот IP какому-то активному сетевому пространству имен
        if ! ip netns exec "$NET_NAME" ip addr show 2>/dev/null | grep -q "10.0.0.$i/"; then
            # Проверяем, нет ли его в ARP-таблице соседей нашего моста
            if ! ip neighbor show dev "$BRIDGE_NAME" | grep -q "10.0.0.$i "; then
                GUEST_IP="10.0.0.$i"
                break
            fi
        fi
    done
    # Если цикл завершился, а переменная осталась пустой — сеть переполненна
    if [ -z "$GUEST_IP" ]; then
        echo "Ошибка: Не удалось автоматически выделить IP-адрес. В подсети 10.0.0.0/24 не осталось свободных адресов!"
        exit 1
    fi
fi
echo "Контейнеру выделен IP-адрес $GUEST_IP"

ip netns add "$NET_NAME"
ip link add "$VETH_HOST" type veth peer name "$VETH_GUEST" netns "$NET_NAME"

ip link set "$VETH_HOST" master "$BRIDGE_NAME"
ip link set "$VETH_HOST" up

# Нативно присваиваем вычисленный или указанный адрес
ip netns exec "$NET_NAME" ip link set "$VETH_GUEST" up
ip netns exec "$NET_NAME" ip addr add "$GUEST_IP/24" dev "$VETH_GUEST"
ip netns exec "$NET_NAME" ip route add default via 10.0.0.1

cp -L /etc/resolv.conf "$MERGED_DIR/etc/resolv.conf" 2>/dev/null || true

if [ -n "$PORT_MAP" ]; then
    # Разрезаем порты по двоеточию
    HOST_PORT=$(echo "$PORT_MAP" | cut -d':' -f1)
    GUEST_PORT=$(echo "$PORT_MAP" | cut -d':' -f2)

    echo "Активация проброса порта: хост $HOST_PORT -> контейнер $GUEST_IP:$GUEST_PORT..."

    # Принудительно разрешаем на хосте перенаправление локального трафика (127.0.0.1) в сеть виртуального моста
    sysctl -w net.ipv4.conf.all.route_localnet=1 > /dev/null
    sysctl -w net.ipv4.conf."$BRIDGE_NAME".route_localnet=1 > /dev/null
    # Очистка старых цепочек NAT
    nft flush table ip nsbox_nat 2>/dev/null || true
    # Добавление цепочки prerouting (для пакетов из внешнего мира)
    nft add chain ip nsbox_nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null || true
    # Выполнение DNAT только для пакетов поступивших извне на реальную сетевую карту хоста,
    # при этом трафик внутри моста 10.0.0.X это правило игнорирует
    nft add rule ip nsbox_nat prerouting iifname "$HOST_IFACE" tcp dport "$HOST_PORT" dnat to "$GUEST_IP:$GUEST_PORT" 2>/dev/null || true
    # Добавление цепочки output (для пакетов, рожденных на самом хосте через localhost)
    nft add chain ip nsbox_nat output { type nat hook output priority -100 \; } 2>/dev/null || true
    # Выполнение локального DNAT только если вы явно стучитесь на 127.0.0.1 (интерфейс lo)!
    nft add rule ip nsbox_nat output oifname "lo" tcp dport "$HOST_PORT" dnat to "$GUEST_IP:$GUEST_PORT" 2>/dev/null || true
    # Маскарадинг (SNAT) для обратного пути
    nft add chain ip nsbox_nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null || true
    nft add rule ip nsbox_nat postrouting ip daddr "$GUEST_IP" tcp dport "$GUEST_PORT" masquerade 2>/dev/null || true
fi

# Настройка графического окружения
if [ "$IS_GUI_ENABLED" = true ]; then
    echo "Подготовка безопасной инфраструктуры X11..."
    mkdir -p "$MERGED_DIR/tmp/.X11-unix"

    # Если на хосте используется Wayland
    if [ -n "$WAYLAND_DISPLAY" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
        mkdir -p "$MERGED_DIR$XDG_RUNTIME_DIR"
    fi
        
    # Напрямую получаем путь к активному ключу X11 из параметров запущенного графического сервера хоста
    REAL_XAUTH=$(ps aux | grep -E 'Xorg|X' | grep -v grep | grep -oE '\-auth [^ ]+' | head -n 1 | cut -d' ' -f2)
        
    # Если секретный файл успешно обнаружен — копируем его в контейнер
    if [ -n "$REAL_XAUTH" ] && [ -f "$REAL_XAUTH" ]; then
        mkdir -p "$MERGED_DIR/root"
        cp -L "$REAL_XAUTH" "$MERGED_DIR/root/.Xauthority" 2>/dev/null || true
        echo "Ключ авторизации X11 $REAL_XAUTH успешно импортирован."
    else
        echo "Предупреждение: Активный файл авторизации X11 не обнаружен."
    fi
        
    # Закрываем шлюз хоста
    xhost -local: >/dev/null 2>&1 || true
fi

# Подготовка путей для проброса каталога в контейнер
if [ -n "$VOLUME_MAP" ]; then
    if [ ! -d "$HOST_PATH" ]; then
        echo "Ошибка: Каталог на хосте '$HOST_PATH' не существует."
        exit 1
    fi
    # Создаем целевую точку монтирования в оверлее, чтобы ядру было куда крепить диск
    mkdir -p "$MERGED_DIR$GUEST_PATH"
fi

# Запуск контейнера
run_nsbox_container

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
    if [ -e "$NET_NS_FILE" ]; then ip netns delete "$NET_NAME" 2>/dev/null || true; fi
    # Удаляем хостовый конец нашего динамического провода veth-$$
    ip link set dev "$VETH_HOST" down 2>/dev/null || true
    ip link delete "$VETH_HOST" 2>/dev/null || true
fi

# Удаление созданной группы cgroups v2, если была создана хотя бы одна настройка
if { [ -n "$MEM_LIMIT" ] || [ -n "$CPU_LIMIT" ]; } && [ -d "$CGROUP_PATH" ]; then
    rmdir "$CGROUP_PATH" 2>/dev/null || true
fi

#!/bin/bash

# Прерывать работу при любой ошибке (безопасный режим)
set -e
# Включить режим allexport, для передачи переменных окружения в nsinit.sh
set -a

# Повышение прав до root'а
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

usage() {
    echo "Использование: $0 [ОПЦИИ] имя_контейнера"
    echo ""
    echo "Опции:"
    echo "  -c, --command 'команда'       Выполнить команду в изолированном контейнере"
    echo "  -l, --lower 'путь'            Указать каталог для нижнего слоя ФС контейнера (вместо корня хоста)"
    echo "  -n, --net auto | ip_addr      Использовать виртуальный адаптер"
    echo "  -p, --port 'хост:контейнер'   Пробросить порт контейнера наружу, например, -p 8080:80"
    echo "  -v, --volume 'хост:контейнер' Пробросить папку хоста внутрь контейнера"
    echo "  -m, --memory 'лимит'          Задать лимит оперативной памяти, например, -m 1G или -m 256M"
    echo "  --cpu 'доля'                  Задать лимит ядер CPU, например, --cpu 1 или --cpu 0.5"
    echo "  -g, --gui                     Разрешить запуск графических приложений внутри контейнера"
    echo "  -d, --detach                  Запустить контейнер в фоновом режиме (демон)"
    echo "  -h, --help                    Показать эту справку и выйти"
    exit 1
}

# Получение ключа авторизации X11 из параметров запущенного графического сервера хоста
REAL_XAUTH=$(ps aux | grep -E 'Xorg|X' | grep -v grep | grep -oE '\-auth [^ ]+' | head -n 1 | cut -d' ' -f2)

# Максимальный размер виртуального диска
MAX_SIZE="16G"
# Определение путей к каталогам
ROOT_DIR="/run/root"
REGISTRY_DIR="/var/lib/nsbox"

# Каталог, используемый в качестве нижнего слоя ФС контейнера
# (по умолчанию - корень файловой исстемы хоста)
LOWER_DIR="/"

VOLUME_MAP=""

# Имя и адрес виртуального моста
BRIDGE_NAME="nsboxbr"
BRIDGE_CIDR="10.0.0.1/24"

# Концы виртуального кабеля
VETH_HOST="veth-$$"
VETH_GUEST="veth-guest"

NET_NAME="nsbox-net"
NET_NS_FILE="/var/run/netns/$NET_NAME"

# Определение сетевой карты хоста с доступом в интернет
HOST_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

IS_NET_ENABLED=false
IS_GUI_ENABLED=false

# Путь к cgroup контейнера
CGROUP_PATH="/sys/fs/cgroup/nsbox"

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
        -l|--lower)
            if [ -n "$2" ]; then
                if [ ! -d "$2" ]; then
                    echo "Ошибка: Каталог нижнего слоя '$2' не найден на хосте!"
                    exit 1
                fi
                LOWER_DIR=$(realpath "$2")
                shift 2
            else
                echo "Ошибка: Флаг --lower требует указания пути к каталогу."; exit 1
            fi
            ;;
        --net)
            # извлечение значения параметра сети, идущего следующим аргументом
            GUEST_IP="$2"
            
            # регулярное выражение для строгой проверки каноничного формата ipv4
            ipv4_regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

            # проверка на пустоту значения или попытку подставить следующий флаг запуска вместо адреса
            if [ -z "$GUEST_IP" ] || [[ "$GUEST_IP" == -* ]]; then
                echo "Ошибка: Флаг --net требует обязательного значения (IP-адрес или 'auto')!"
                exit 1
            fi

            # проверка соответствия значения разрешенным параметрам auto или валидному ip
            if [ "$GUEST_IP" != "auto" ] && [[ ! "$GUEST_IP" =~ $ipv4_regex ]]; then
                echo "Ошибка: Некорректное значение флага --net. Допускается только IP-адрес или 'auto'!"
                exit 1
            fi

            # активация сетевого флага проекта при успешном прохождении валидации
            IS_NET_ENABLED=true
            shift 2
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
                # Проверка формата регулярным выражением (целое число или дробь через точку)
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
            if [[ "$1" =~ ^- ]] || [ "$#" -ne 1 ]; then
                echo "Неизвестный параметр: $1"
                usage
            fi
            GUEST_NAME="$1"
            shift 1
            ;;
    esac
done

# Динамическое формирование сетевого префикса
if [ "$IS_NET_ENABLED" = true ]; then
    # Подключение готовой сети хоста
    NET_PREFIX="nsenter --net=$NET_NS_FILE"
else
    # Пустая сеть
    NET_PREFIX="--net"
fi

if [ -z "$GUEST_NAME" ]; then
    echo "Ошибка: Не указано имя контейнера"
    echo ""
    usage
fi

if [[ "$GUEST_NAME" == *"/"* ]]; then
    echo "Ошибка: Задано недопустимое имя контейнера '$GUEST_NAME'."
    echo "Имя должно быть простым идентификатором без слэшей."
    exit 1
fi

# Динамически собираем пути к рантайму контейнера
BASE_DIR="$REGISTRY_DIR/$GUEST_NAME"
UPPER_DIR="$BASE_DIR/upper"
WORK_DIR="$BASE_DIR/work"
MERGED_DIR="$BASE_DIR/merged"
IMAGE_FILE="$BASE_DIR/$GUEST_NAME.img"

# Подготовка структуры каталогов рантайма контейнера
mkdir -p "$ROOT_DIR" "$BASE_DIR"

# Создание виртуального жесткого диска (в разреженном файле)
if [ ! -f "$IMAGE_FILE" ]; then
    echo "Создание разреженного $IMAGE_FILE с максимальным размером $MAX_SIZE..."
    truncate -s "$MAX_SIZE" "$IMAGE_FILE"
    echo "Форматирование $IMAGE_FILE в ext4..."
    mkfs.ext4 -F "$IMAGE_FILE"
fi

# Монтирование виртуального диска в базовый каталог
if ! mountpoint -q "$BASE_DIR"; then
    mount -o loop,user_xattr "$IMAGE_FILE" "$BASE_DIR"
fi

mkdir -p "$UPPER_DIR" "$WORK_DIR" "$MERGED_DIR"

# Сборка OverlayFS в MERGED_DIR
if ! mountpoint -q "$ROOT_DIR"; then mount --bind "$LOWER_DIR" "$ROOT_DIR"; fi
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
if [ "$IS_NET_ENABLED" = true ]; then
    # Определение и экспорт ip-адреса и маски шлюза
    export bridge_ip="${BRIDGE_CIDR%/*}"
    export bridge_mask="${BRIDGE_CIDR#*/}"

    if [ "$GUEST_IP" = "$bridge_ip" ]; then
        echo "Ошибка: Адрес $GUEST_IP занят виртуальным мостом хоста (шлюзом)."
        exit 1
    fi

    echo "Настройка сети через виртуальный мост $BRIDGE_NAME..."
    
    nft delete table ip nsbox_nat 2>/dev/null || true

    if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        ip link add "$BRIDGE_NAME" type bridge
        ip addr add "$BRIDGE_CIDR" dev "$BRIDGE_NAME"
        ip link set "$BRIDGE_NAME" up
    fi

    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
    # Инициализируем таблицу и базовую цепочку
    nft add table ip nsbox_nat 2>/dev/null || true
    nft add chain ip nsbox_nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null || true
    
    # Автоматический расчет адреса сети для маскарадинга
    mask_num=$(( 0xFFFFFFFF << (32 - bridge_mask) ))
    
    IFS=. read -r i1 i2 i3 i4 <<< "$bridge_ip"
    bridge_num=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
    
    network_num=$(( bridge_num & mask_num ))
    broadcast_num=$(( network_num | (~mask_num & 0xFFFFFFFF) ))
    
    net_addr="$(( (network_num >> 24) & 255 )).$(( (network_num >> 16) & 255 )).$(( (network_num >> 8) & 255 )).$(( network_num & 255 ))"

    # Маскарадинг подсети на основе вычисленного сетевого адреса
    nft add rule ip nsbox_nat postrouting ip saddr "$net_addr/$bridge_mask" masquerade 2>/dev/null || true

    # Автовыбор IP-адреса для контейнера, если GUEST_IP равен 'auto'
    if [ "$GUEST_IP" = "auto" ]; then
        # Определение первого и последнего доступного ip-хоста в подсети
        start_num=$(( network_num + 1 ))
        end_num=$(( broadcast_num - 1 ))

        # Сбор занятых ipv4-адресов подсети
        busy_ips=$( { ip addr show master "$BRIDGE_NAME"; ip neighbor show dev "$BRIDGE_NAME"; } 2>/dev/null | grep -oE "${bridge_ip%.*}\.[0-9]+" | tr '\n' ' ' )
        busy_ips="$busy_ips $bridge_ip"

        # Перебор хостов внутри диапазона подсети
        GUEST_IP=""
        for ((num=start_num; num<=end_num; num++)); do
            test_ip="$(( (num >> 24) & 255 )).$(( (num >> 16) & 255 )).$(( (num >> 8) & 255 )).$(( num & 255 ))"
            
            if [[ " $busy_ips " != *" $test_ip "* ]]; then
                GUEST_IP="$test_ip"
                break
            fi
        done

        if [ -z "$GUEST_IP" ]; then
            echo "Ошибка: Не удалось автоматически выделить IP-адрес. В подсети $BRIDGE_CIDR не осталось свободных адресов!"
            exit 1
        fi
    fi
    echo "Контейнеру выделен IP-адрес $GUEST_IP"

    # Если файл дескриптора netns застрял в памяти — принудительно удаляем его перед стартом
    if [ -e "/run/netns/$NET_NAME" ]; then
        umount -l "/run/netns/$NET_NAME" 2>/dev/null || true
        rm -f "/run/netns/$NET_NAME" 2>/dev/null || true
        ip netns delete "$NET_NAME" 2>/dev/null || true
    fi

    # Создание пространства $NET_NAME и виртуального кабеля $VETH_HOST <-> "$VETH_GUEST"
    ip netns add "$NET_NAME"
    ip link add "$VETH_HOST" type veth peer name "$VETH_GUEST" netns "$NET_NAME"

    ip link set "$VETH_HOST" master "$BRIDGE_NAME"
    ip link set "$VETH_HOST" up

    cp -L /etc/resolv.conf "$MERGED_DIR/etc/resolv.conf" 2>/dev/null || true
else
    echo "" > "$MERGED_DIR/etc/resolv.conf"
fi

# Настройка проброса портов
if [ -n "$PORT_MAP" ]; then
    # Извлечение номеров порта хоста и порта контейнера
    HOST_PORT="${PORT_MAP%%:*}"
    GUEST_PORT="${PORT_MAP#*:}"

    # Вывод информационного сообщения об инициализации трансляции портов
    echo "Активация проброса порта: хост $HOST_PORT -> контейнер $GUEST_IP:$GUEST_PORT..."

    # Атомарное создание таблицы маршрутизации ip-пакетов с именем nsbox_nat
    nft add table ip nsbox_nat 2>/dev/null || true
    
    # Создание цепочки предварительной маршрутизации для входящего сетевого трафика
    nft add chain ip nsbox_nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null || true
    # dnat для входящих пакетов из внешних интерфейсов (исключая сетевой мост)
    nft add rule ip nsbox_nat prerouting iifname != "$BRIDGE_NAME" tcp dport "$HOST_PORT" dnat to "$GUEST_IP:$GUEST_PORT" 2>/dev/null || true

    # Создание цепочки маршрутизации для исходящего трафика, генерируемого самим хостом
    nft add chain ip nsbox_nat output { type nat hook output priority -100 \; } 2>/dev/null || true
    # dnat для локальных пакетов хоста, адресованных строго на ip-адрес шлюза моста
    nft add rule ip nsbox_nat output ip daddr 10.0.0.1 tcp dport "$HOST_PORT" dnat to "$GUEST_IP:$GUEST_PORT" 2>/dev/null || true

    # Создание цепочки пост-маршрутизации для изменения сетевых адресов перед отправкой пакета
    nft add chain ip nsbox_nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null || true
    # Ммаскарадинг источника для корректного возврата ответов от контейнера к хосту
    nft add rule ip nsbox_nat postrouting ip daddr "$GUEST_IP" tcp dport "$GUEST_PORT" masquerade 2>/dev/null || true
fi

# Настройка графического окружения
if [ "$IS_GUI_ENABLED" = true ]; then
    echo "Подготовка безопасной инфраструктуры X11..."
    mkdir -p "$MERGED_DIR/tmp/.X11-unix"

    if [ -d "$XDG_RUNTIME_DIR" ]; then
        # Создание целевой папки внутри оверлея контейнера
        mkdir -p "$MERGED_DIR$XDG_RUNTIME_DIR"
        # Монтирование папки сокетов хоста в изолированный корень контейнера
        mount --bind "$XDG_RUNTIME_DIR" "$MERGED_DIR$XDG_RUNTIME_DIR"
    fi
    
    # Копирование файла авторизации .Xauthority в виртуальное окно merged
    if [ -n "$REAL_XAUTH" ] && [ -f "$REAL_XAUTH" ]; then
        mkdir -p "$MERGED_DIR/root"
        cp -L "$REAL_XAUTH" "$MERGED_DIR/root/.Xauthority" 2>/dev/null || true
        echo "Ключ авторизации X11 $REAL_XAUTH успешно импортирован."
    else
        echo "Предупреждение: Активный файл авторизации X11 не обнаружен по пути: '$REAL_XAUTH'"
    fi
fi

# Подготовка путей для проброса каталога в контейнер
if [ -n "$VOLUME_MAP" ]; then
    # Если каталога на хосте не существует — автоматически создаем его, 
    # чтобы не ломать запуск контейнера из-за отсутствующих пустых папок
    if [ ! -d "$HOST_PATH" ]; then
        echo "Предупреждение: Каталог '$HOST_PATH' на хосте не найден. Создаю автоматически..."
        mkdir -p "$HOST_PATH"
    fi
    
    # Создание целевой точки монтирования в оверлее, чтобы ядру было куда крепить диск
    mkdir -p "$MERGED_DIR$GUEST_PATH"
fi

# Запуск контейнера
unshare --mount --pid --fork --propagation private $NET_PREFIX $(dirname "$(realpath "$0")")/nsinit.sh

# Удаление точки монтирования из верхнего слоя изменений
if [ -n "$VOLUME_MAP" ] && [ -d "$UPPER_DIR$GUEST_PATH" ]; then
    rmdir "$UPPER_DIR$GUEST_PATH" 2>/dev/null || true
fi

echo "Размонтирование дисков хоста..."
umount -l "$MERGED_DIR" 2>/dev/null || true
umount -l "$ROOT_DIR"   2>/dev/null || true
umount -l "$BASE_DIR"   2>/dev/null || true

echo "Очистка сетевых ресурсов хоста..."
if [ -n "$VETH_HOST" ] && [ -d "/sys/class/net/$VETH_HOST" ]; then
    ip link set dev "$VETH_HOST" down 2>/dev/null || true
    ip link delete "$VETH_HOST" 2>/dev/null || true
fi

# Зачистка пространства имен
if [ -e "$NET_NS_FILE" ]; then
    # Ленивое отмонтирование файл-маркера
    umount -l "$NET_NS_FILE" 2>/dev/null || true
    # Удаление пространство из системы
    ip netns delete "$NET_NAME" 2>/dev/null || true
fi

# Удаление созданной cgroups, если была создана
if [ -d "$CGROUP_PATH" ]; then
    echo "Удаление контрольной группы cgroups контейнера..."
    rmdir "$CGROUP_PATH" 2>/dev/null || true
fi

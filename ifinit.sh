#!/bin/bash

# Файл конфигурации
CONFIG_FILE="ifaces.conf"

# Функция проверки формата IP
is_valid_ip() {
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

# Функция генерации адреса шлюза X.X.X.1
get_gateway() {
    echo "$1" | cut -d. -f1-3 | sed 's/$/.1/'
}

# Проверка прав root и наличия файла конфигурации
[[ $EUID -ne 0 ]] && { echo "Error: Run as root"; exit 1; }
[[ ! -f "$CONFIG_FILE" ]] && { echo "Error: $CONFIG_FILE not found"; exit 1; }

echo "Starting interface configuration..."

# Перебор всех физических интерфейсов в /sys/class/net
for IFACE_PATH in /sys/class/net/*; do
    INTERFACE=$(basename "$IFACE_PATH")
    
    # Пропуск loopback и виртуальных сущностей без MAC
    [[ "$INTERFACE" == "lo" ]] || [[ ! -f "$IFACE_PATH/address" ]] && continue

    MAC=$(cat "$IFACE_PATH/address" | tr '[:upper:]' '[:lower:]')
    
    # Поиск текущего MAC в конфигурационном файле
    MATCH=$(grep -vE '^\s*(#|$)' "$CONFIG_FILE" | grep -i "$MAC")

    if [[ -n "$MATCH" ]]; then
        # Извлечение IP и hostname
        read -r _ IP HOSTNAME <<< "$MATCH"
        
        if ! is_valid_ip "$IP"; then
            echo "Error: Invalid IP '$IP' for interface $INTERFACE ($MAC)"
            continue
        fi

        echo "Configuring $INTERFACE ($MAC)..."

        # Установка Hostname (выполняется для каждого совпадения, 
        # фактически установится имя от последнего совпавшего интерфейса в цикле)
        echo "$HOSTNAME" > /etc/hostname
        sed -i "/^127.0.1.1/d" /etc/hosts
        echo -e "127.0.1.1\t$HOSTNAME" >> /etc/hosts

        # Настройка сетевых интерфейсов
        GATEWAY=$(get_gateway "$IP")

        # Проверить наличие настроек NetworkManager, если есть использовать их
        if [[ -d /etc/NetworkManager ]]; then
            # NetworkManager Keyfile
            NM_DIR="/etc/NetworkManager/system-connections"
            mkdir -p "$NM_DIR" && rm -rf "$NM_DIR"/*
            NM_CONF="$NM_DIR/$INTERFACE.nmconnection"
            
            # Генерация UUID для каждого интерфейса
            UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)-$INTERFACE")

            cat <<EOF > "$NM_CONF"
[connection]
id=$INTERFACE
uuid=$UUID
type=ethernet
interface-name=$INTERFACE

[ethernet]
mac-address=$MAC

[ipv4]
address1=$IP/24,$GATEWAY
method=manual

[ipv6]
method=auto
EOF
            chmod 600 "$NM_CONF"
            echo "Successfully created NM profile for $INTERFACE"

        # NetworkManager не обнаружен использовать настройки networking
        elif [[ -d /etc/network ]]; then
            CONF_DIR="/etc/network/interfaces.d"
            mkdir -p "$CONF_DIR"
            CONF_PATH="$CONF_DIR/$INTERFACE"

            cat <<EOF > "$CONF_PATH"
auto $INTERFACE
iface $INTERFACE inet static
    address $IP
    netmask 255.255.255.0
    gateway $GATEWAY
EOF
            echo "Successfully created interface config for $INTERFACE"
        fi
    else
        echo "No config found for $INTERFACE ($MAC), skipping..."
    fi
done

echo "Configuration process finished"

# Памятка по формату `ifaces.conf`

# MAC-адрес       IP-адрес     Имя хоста

#c8:ff:bf:01:1c:71 192.168.1.10 arm-o
#aa:bb:cc:dd:ee:ff 192.168.1.11 arm-abi

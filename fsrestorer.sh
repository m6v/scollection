#!/bin/sh

# Скрипт восстановления загрузочного диска из архива fsarchiver
# Использование: sudo ./fsrestorer.sh /путь/к/архиву.fsa

# Проверка аргумента
ARCHIVE_PATH="$1"

if [ -z "$ARCHIVE_PATH" ]; then
    echo "$0: не указан путь к архиву"
    echo "Использование: $0 /path/to/backup.fsa"
    exit 1
fi

if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "$0: файл '$ARCHIVE_PATH' не найден"
    exit 1
fi

# Вывод информация об архиве
echo "--------------------------------------------------------"
fsarchiver archinfo "$ARCHIVE_PATH"
echo "--------------------------------------------------------"

# Выбор целевого диска (POSIX style)
echo ""
echo "Доступные диски:"

# Генерируем временный список дисков
DISK_LIST=$(parted -l 2>/dev/null | grep "/dev/" | grep -vE "loop|sr[0-9]" | sed 's/Disk //')

if [ -z "$DISK_LIST" ]; then
    echo "$0: накопители не найдены"
    exit 1
fi

# Выводим список с номерами через nl
echo "$DISK_LIST" | nl

echo ""
read -p "Введите номер диска и нажмите Enter для продолжения или Ctrl+C для выхода: " -r CHOICE

# Извлекаем выбранную строку по номеру
OPT=$(echo "$DISK_LIST" | sed -n "${CHOICE}p")

if [ -z "$OPT" ]; then
    echo "$0: неверный выбор диска"
    exit 1
fi

# Извлекаем путь к диску (все до двоеточия)
DISK=$(echo "$OPT" | cut -d':' -f1)
echo "Выбран диск: $DISK"

# Параметры и подтверждение
EFI_SIZE=512
SWAP_SIZE=4096
EFI_END=$((EFI_SIZE + 1))
SWAP_END=$((EFI_END + SWAP_SIZE))

echo -e "\n!!! ВНИМАНИЕ !!!"
echo "Все данные на $DISK будут УДАЛЕНЫ."
read -p "Продолжить? (y/n): " -r confirm
[ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && echo "Отмена." && exit 1

# Определение имен разделов (проверка на цифру в конце имени для NVMe)
if echo "$DISK" | grep -q "[0-9]$"; then
    PART_EFI="${DISK}p1"
    PART_SWAP="${DISK}p2"
    PART_ROOT="${DISK}p3"
else
    PART_EFI="${DISK}1"
    PART_SWAP="${DISK}2"
    PART_ROOT="${DISK}3"
fi

# Выполнение команд
echo "Разметка диска..."
parted -s "$DISK" mklabel gpt \
    mkpart primary fat32 1MiB ${EFI_END}MiB \
    set 1 esp on \
    mkpart primary linux-swap ${EFI_END}MiB ${SWAP_END}MiB \
    mkpart primary ext4 ${SWAP_END}MiB 100%

sleep 2
[ -f /sbin/udevadm ] && udevadm settle

echo "Форматирование разделов EFI и swap..."
mkfs.vfat -F32 "$PART_EFI"
mkswap "$PART_SWAP"

echo "Восстановление корневого раздела..."
fsarchiver restfs "$ARCHIVE_PATH" id=0,dest="$PART_ROOT"

echo "Монтирование виртуальных ФС..."
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$PART_EFI" /mnt/boot/efi

for dir in dev dev/pts proc sys run; do
    mount --bind /$dir /mnt/$dir
done

echo "Настройка точек монтирования в fstab..."
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")
SWAP_UUID=$(blkid -s UUID -o value "$PART_SWAP")

cat <<EOF > /mnt/etc/fstab
UUID=$ROOT_UUID  /               ext4    errors=remount-ro 0 1
UUID=$EFI_UUID   /boot/efi       vfat    umask=0077      0 2
UUID=$SWAP_UUID  none            swap    sw              0 0
EOF

echo "Установка загрузчика grub..."
chroot /mnt /bin/sh <<CHROOT_EOF
grub-install "$DISK"
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_EOF

echo "Размонтирование ФС..."
umount /mnt/boot/efi
for dir in pts dev proc sys run; do umount /mnt/dev/$dir 2>/dev/null || umount /mnt/$dir; done
umount /mnt

echo "Готово!"
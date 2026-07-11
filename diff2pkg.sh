#!/bin/bash

# Функция вывода справки
usage() {
    echo "Использование: $0 [путь] <файл> <фильтр_времени> [-k | --keep] [-l | --follow]"
    echo "Находит измененные за заданный период времени файлы и собирает из них либо DEB-пакет, либо TAR-архив (.tar, .tgz, .tar.gz)"
    echo ""
    echo "Обязательные параметры:"
    echo "  фильтр_времени    Любые флаги фильтрации по времени, используемые в утилите find, например, -mmin -5, -mtime -1"
    echo "  <файл>            Имя создаваемого DEB-пакета (.deb) или архива (.tar, .tgz, .tar.gz)"
    echo ""
    echo "Необязательные параметры:"
    echo "  [путь]            Каталог для поиска (по умолчанию текущий каталог '.')"
    echo "  -k, --keep        Не удалять временный каталог с файлами после сборки"
    echo "  -l, --follow      Автоматически добавлять файлы, на которые указывают ссылки"
    echo ""
    echo "Примеры вызова:"
    echo "  $0 -mmin -10 backup.tar.gz"
    echo "  $0 /usr/local patch.deb -mtime -1 --keep --follow"
    exit 1
}

SRC_DIR=""
OUT_FILE=""
TIME_PARAMS=()
POSITIONAL_ARGS=()
KEEP_BUILD_DIR=false 
FOLLOW_LINKS=false    

# Цикл разбора аргументов командной строки
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -k|--keep)
            KEEP_BUILD_DIR=true
            shift 1
            ;;
        -l|--follow)
            FOLLOW_LINKS=true
            shift 1
            ;;
        -mmin|-mtime|-amin|-atime|-cmin|-ctime|-newer*)
            TIME_PARAMS+=("$1" "$2") 
            shift 2
            ;;
        -*)
            echo "Ошибка: Неизвестный флаг $1"
            usage
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift 1
            ;;
    esac
done

if [ ${#TIME_PARAMS[@]} -eq 0 ] || [ ${#POSITIONAL_ARGS[@]} -eq 0 ]; then
    echo "Ошибка: Не указаны обязательные параметры"
    usage
fi

# Разделение аргументов
if [ ${#POSITIONAL_ARGS[@]} -eq 1 ]; then
    OUT_FILE="${POSITIONAL_ARGS[0]}"
    SRC_DIR="."
else
    SRC_DIR="${POSITIONAL_ARGS[0]}"
    OUT_FILE="${POSITIONAL_ARGS[1]}"
fi

SRC_DIR=$(realpath "$SRC_DIR")
OUT_FILE=$(realpath "$OUT_FILE")
SCRIPT_PATH=$(realpath "$0")

BUILD_DIR=$(mktemp -d -t build_zone_XXXXXX)

# Функция автоматической очистки
cleanup() {
    [ -d "$BUILD_DIR" ] || return

    if [ "$KEEP_BUILD_DIR" = false ]; then
        rm -rf "$BUILD_DIR"
    else
        echo "Временный каталог сохранен: $BUILD_DIR"
        if [[ "$OUT_FILE" == *.deb ]]; then
            echo "Для сборки пакета выполните команду: dpkg-deb --build \"$BUILD_DIR\" \"$OUT_FILE\""
        else
            echo "Для сборки архива выполните команду: tar -czvf \"$OUT_FILE\" -C \"$BUILD_DIR\" ."
        fi
    fi
}
trap cleanup EXIT SIGINT SIGTERM

EXCLUDES=(
    -path "/tmp" -o -path "/proc" -o -path "/sys" -o -path "/dev" -o -path "/run"
    -o -path "$OUT_FILE" -o -path "$SCRIPT_PATH" -o -path "$BUILD_DIR"
)

# Поиск и копирование измененных файлов и ссылок во временную зону
find "$SRC_DIR" \( "${EXCLUDES[@]}" \) -prune -o \( -type f -o -type l \) "${TIME_PARAMS[@]}" -print0 | tar --null -T - -cf - | tar -xf - -C "$BUILD_DIR"

# Проверка наличия файлов
if [ -z "$(ls -A "$BUILD_DIR")" ]; then
    echo "Предупреждение: Измененных файлов не найдено. Сборка отменена."
    exit 0
fi

# Проверка и автокопирование файлов по ссылккам
echo "Проверка целостности символических ссылок внутри сборки..."
while read -r -d '' link_path; do
    target=$(readlink "$link_path")
    
    if [[ "$target" = /* ]]; then
        real_system_target="$target"
    else
        link_dir_real=$(dirname "${link_path#$BUILD_DIR}")
        real_system_target=$(realpath -m "$SRC_DIR/$link_dir_real/$target")
    fi

    full_target_path="$BUILD_DIR$real_system_target"

    if [ ! -e "$full_target_path" ]; then
        display_link="${link_path#$BUILD_DIR}"
        
        if [ "$FOLLOW_LINKS" = true ] && [ -e "$real_system_target" ]; then
            echo "Автодобавление: Ссылка [$display_link] требует файл [$real_system_target]. Копируем..."
            (cd / && cp -a --parents ".${real_system_target}" "$BUILD_DIR/")
            KEEP_BUILD_DIR=true
        else
            echo "Предупреждение: Ссылка [$display_link] ведет на отсутствующий в пакете объект [$target]"
            KEEP_BUILD_DIR=true
        fi
    fi
done < <(find "$BUILD_DIR" -type l -print0)

# Выбор действия по типу файла
if [[ "$OUT_FILE" == *.deb ]]; then
    # Сборка DEB-пакета
    PKG_NAME=$(basename "$OUT_FILE" .deb)
    mkdir -p "$BUILD_DIR/DEBIAN"

    echo "Генерация контрольных сумм md5sums..."
    ( cd "$BUILD_DIR" && find . -type f ! -path "./DEBIAN/*" -print0 | xargs -0 md5sum > DEBIAN/md5sums )

    cat << EOF > "$BUILD_DIR/DEBIAN/control"
Package: $PKG_NAME
Version: 1.0.$(date +%Y%m%d%H%M)
Architecture: all
Maintainer: Sergey Maksimov <m6v@mail.ru>
Description: Автоматический пакет обновлений измененных файлов
EOF

    echo "Сборка пакета $OUT_FILE..."
    dpkg-deb --build "$BUILD_DIR" "$OUT_FILE"
else
    # Сборка ТАР-архива
    echo "Сборка архива $OUT_FILE..."
    if [[ "$OUT_FILE" == *.tgz ]] || [[ "$OUT_FILE" == *.tar.gz ]]; then
        tar -czf "$OUT_FILE" -C "$BUILD_DIR" .
    else
        tar -cf "$OUT_FILE" -C "$BUILD_DIR" .
    fi
fi

echo "$OUT_FILE успешно создан"

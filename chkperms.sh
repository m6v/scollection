#!/usr/bin/env bash

VERSION=1.13

# Используемые escape-последовательности
el='\033[K' # Стереть от курсора до конца строки
nc='\033[0m' # Нет цвета
red='\033[0;31m' # Красный
green='\033[0;32m' # Зеленый

usage(){
    echo "Использование: $(basename $0) [-h|-v|-p|--version] ФАЙЛ..."
    echo "Проверяет соответствие прав доступа к файлам и каталогам матрице доступа"
    echo
    echo "  -h, --help     показать эту справку и выйти"
    echo "  -v, --verbose  показать успешные проверки"
    echo "  -p, --progress показать индикатор програсса выполнения"
    echo "  --version      показать информацию о версии и выйти"
    echo "  ФАЙЛ           файл с матрицей даступа"
}

progress(){
    percent=$(($1 * 100 / ${total}))
    # Количество знаков индикатора прогресса с учетом ширины терминала
    sharps=$(($1 * (${tcols} - 5) / ${total}))
    # escape-последовательность для повторения символа перед ней несколько раз (REP) \e[n;b
    # см.: https://invisible-island.net/xterm/ctlseqs/ctlseqs.pdf (стр. 12)
    printf [%d%%]"#\e[%d;b\r" $percent $sharps
}

# Присвоить переменной указатель на пустую операцию
show_progress=(:)

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit
            ;;
        -v|--verbose)
            verbose=true
            ;;
        -p|--progress)
            # Присвоить переменной указатель на функцию отображения индикатора прогресса
            show_progress=(progress)
            ;;     
        --version)
            echo $(basename $0) $VERSION
            exit
            ;;
        *)
            file=$1
            ;;
    esac
    shift
done

if [ ! -f "$file" ]; then
    echo "$(basename $0): файл с матрицей доступа не задан или не найден" >&2
    exit
fi

total=$(cat $file | wc -l)
# Поучить число колонок в окне терминала 
tcols=$(tput cols)

# Присвоить переменной ID идентификатор дистрибутива
eval $(grep ^ID= /etc/os-release)

# Определить функцию чтения прав доступа в зависимости от используемого дистрибутива Linux
# Используется eval, т.к. иначе проблемы с файлами в именах которых есть пробелы!
if [ "$ID" == "astra" ]; then
    getperms(){ eval "pdp-ls -daM --time-style=+ '$@' | cut -d' ' -f1,4-";}
else
    getperms(){ eval "ls -dl --time-style=+ '$@' | cut -d' ' -f1,3,4,7-";}
fi

if [ $(id -u) -ne 0 ]; then
    echo "$(basename $0): запустите программу с правами суперпользователя"
    exit
fi

checks=0
errors=0

echo "Проверка прав доступа..."
while read -r line; do
    $show_progress $checks
    ((checks++))
    # $(expr index "$line" /) возвращает позицию (отсчет с единицы) первого слеша в строке,
    # ${line:pos-1} возвращает подстроку начиная с pos-1 до конца строки
    fname=${line:$(expr index "$line" /)-1}
    if [ ! -e "${fname}" ]; then
        echo -e "${fname} ...нет такого файла или каталога${el}"
        continue
    fi
    # Получить права доступа очередного объекта
    # NB! Кавычки обязательны, иначе множественные пробелы усекаются до одного
    perms=$(getperms "${fname}")
    # Сравнить полученные права доступа с правами в матрице доступа
    if [ "$perms" != "$line" ]; then
        ((errors++))
        echo -e "${fname} ...${red}ошибка${nc}${el}"
        continue  
    fi

    if [ -n "$verbose" ]; then
        # Вывести сообщение и затереть индикатор прогресса
        echo -e "${fname} ...${green}успешно${nc}${el}"
    fi
done <$file

echo "Проверено объектов ${checks}, ошибок ${errors}"

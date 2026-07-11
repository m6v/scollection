#!/usr/bin/env bash

# Однострочная замена скрипта
# find dir_name \! -type l -exec ls -dal --time-style=+ {} \; | cut -d' ' -f1,3,4,7-
# find dir_name \! -type l -exec pdp-ls -daM --time-style=+ {} \; | cut -d' ' -f1,4-

VERSION=1.04

usage() {
    echo "Использование: $(basename $0) [-h|-v] [КАТАЛОГ]..."
    echo "Выводит права доступа к файлам и каталогам, находящимся в указанном(ых) каталоге(ах),"
    echo "если каталог не задан, то начиная с корневого каталога"
    echo
    echo "  -h, --help    показать эту справку и выйти"
    echo "  -v, --version показать информацию о версии и выйти"
}

while [ "$#" -gt 0 ]; do
    case $1 in
        -h|--help)
             usage
             exit
             ;;
        -v|--version)
            echo $(basename $0) $VERSION
            exit
            ;;
        *)
            if [ ! -d $1 ]; then
                echo "$(basename $0): каталог $1 не существует" >&2
                exit
            fi
            dirs+=" $1"
            ;;
    esac
    shift
done

if [ -z "$dirs" ]; then
    dirs="/"
fi

if [ $(id -u) -ne 0 ]; then
    echo "$(basename $0): запустите программу с правами суперпользователя"
    exit
fi

# Присвоить переменной ID идентификатор дистрибутива
eval $(grep ^ID= /etc/os-release)

# Сформировать шаблон команды чтения атрибутов объектов доступа
if [ "$ID" == "astra" ]; then
    cmd="find %s \! -type l -exec pdp-ls -daM --time-style=+ {} \; | cut -d' ' -f1,4-"
else
    cmd="find %s \! -type l -exec ls -dal --time-style=+ {} \; | cut -d' ' -f1,3,4,7-"
fi

for dir in $dirs; do
    eval $(printf "$cmd" "$dir")
done

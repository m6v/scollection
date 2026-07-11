#!/usr/bin/env python3
import argparse
import os
import platform
import sys
import subprocess

def show_perms(path):
    try:

        # Пропустить симлинки
        if os.path.islink(path):
            return

        entries = os.scandir(path)
        for entry in entries:
            # Пропустить симлинки
            if entry.is_symlink():
                continue
            # Получить полный путь к объекту ФС (entry.name - только имя объекта)
            path = entry.path

            if 'astra' in platform.version():
                # Команда для ОС "Astra Linux SE"
                cmd = "pdp-ls -daM --time-style=+ '%s' | awk -v ORS='' '{print $3, $4, $1, $5}'" % path
            else:
                # Команда для ОС GNU/Linux
                cmd = "ls -dal --time-style=+ '%s' | awk -v ORS='' '{print $3, $4, $1}'" % path

            output = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).communicate()[0]
            print(path, output.decode('utf-8'), sep='\n')

            if entry.is_file():
                continue

            # Пропустить точки монтирования виртуальных файловых систем и какалог временных файлов
            if not path in ('/dev', '/media', '/parsecfs', '/proc', '/run', '/sys', '/tmp'):
                # Рекурсивный обход вложенного каталога
                show_perms(path)

    except (FileNotFoundError, OSError)  as e:
        pass

def main ():
    parser = argparse.ArgumentParser(description='Программа создания списка разрешений объектов доступа')
    parser.add_argument("path", nargs='?', default='/', help="Исходный каталог с объектами доступа (по умолчанию '/')")
    args = parser.parse_args()

    if not os.path.isdir(args.path):
        print('Ошибка: каталог', args.path, 'не существует!')
        quit()

    try:
        show_perms(args.path)
    except FileNotFoundError as e:
        print(e)

if __name__ == '__main__':
    main()

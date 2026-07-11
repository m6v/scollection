#!/usr/bin/env python3
import argparse
import os
import platform
import socket
import sys
import subprocess

def get_lines_count(filename):
    '''
    Подсчет количества строк в файле
    '''
    try:
        f = open(filename)
        lines = 0
        buf_size = 1024 * 1024

        buf = f.read(buf_size)
        while buf:
            lines += buf.count('\n')
            buf = f.read(buf_size)
        f.close

    except FileNotFoundError as e:
        print("Файл с контрольными суммами каталогов и файлов не найден")
        quit()

    return lines

def main():
    parser = argparse.ArgumentParser(description='Программа проверки соответствия разрешений каталогов и файлов матрице доступа')
    parser.add_argument('-v', action='store_true', help='Выводить успешные результаты')
    parser.add_argument('-s', action='store_true', help='Выводить сообщения об отсутствии каталогов и файлов')
    parser.add_argument('filename', nargs='?', default=socket.gethostname().split('.', 1)[0],
                        help='Файл со списком разрешений каталогов и файлов (по умолчанию: файл в текущем каталоге с именем, соответствующем имени хоста)')

    args = parser.parse_args()

    allchecks = get_lines_count(args.filename) // 2
    failurechecks = 0

    try:
        with open(args.filename, 'r') as file:
            for i in range(allchecks):
                # В нечетных строках имена объектов доступа
                line = file.readline()
                path = line.strip()
                # В четных строках разрешения объектов доступа
                line = file.readline()
                perms = line.strip()

                percent = format((i+1)*100/allchecks, '.2f')
                if not os.path.exists(path):
                    if args.s:
                        failurechecks += 1
                        print(percent + '% \33[31m' + '[Ошибка!]' + '\033[0m', 'Объект', path, 'отсутствует')
                    continue

                if 'astra' in platform.version():
                    # Команда для ОС "Astra Linux SE"
                    cmd = "pdp-ls -daM --time-style=+ '%s' | awk -v ORS='' '{print $3, $4, $1, $5}'" % path
                else:
                    # Команда для ОС GNU/Linux
                    cmd = "ls -dal --time-style=+ '%s' | awk -v ORS='' '{print $3, $4, $1}'" % path

                output = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).communicate()[0]

                if perms == output.decode('utf-8'):
                    if args.v:
                        print(percent + '% \33[32m' + '[Успешно]' + '\033[0m', 'Проверка', path)
                else:
                    failurechecks += 1
                    print(percent + '% \33[31m' + '[Ошибка!]' + '\033[0m', 'Проверка', path)
                    print(perms, output.decode('utf-8'), sep='\n')

        print ('Всего проверок: ', allchecks)
        print ('Неудачных: ', '\33[31m' + str(failurechecks) + '\033[0m')

    except FileNotFoundError as e:
        print(e)

if __name__ == '__main__':
    main()

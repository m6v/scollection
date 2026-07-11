#!/usr/bin/env python3
import argparse
import grp
import os
import pwd
import stat
import sys

def main():
    parser = argparse.ArgumentParser(description='Программа создания списка каталогов и файлов с нестандартными правами')
    parser.add_argument('-d', '--always-show-dirs', dest='always_show_dirs', action='store_true', help='Показывать каталоги вне зависимости от их прав доступа')
    parser.add_argument('-f', '--show-full-paths', dest='show_full_paths', action='store_true', help='Показывать полные пути к файлам')
    parser.add_argument('path', nargs='?', default='/', help="Исходный каталог с объектами доступа (по умолчанию '/')")
    global args 
    args = parser.parse_args()
    
    if not os.path.isdir(args.path):
        print('Ошибка: каталог', args.path, 'не существует!')
        quit()
        
    # список каталогов-исключений 
    # TODO автоматиески получать списк виртуальных ФС
    excluded_dirs = ('/dev', '/media', '/mnt', '/parsecfs', '/proc', '/run', '/sys', '/tmp', '/var/tmp')
    # списк каталогов с исполняемыми файлами
    executed_dirs = os.environ['PATH'].split(':')
      
    for root, dirs, files in os.walk(args.path):
        try:
            # не итерировать файлы в указанных каталогах
            if root.startswith(excluded_dirs):
                continue
            
            # TODO Здесь проверять права и владельца каталога и, если они не стандартые выводить каталог
            #      в каталоге /home владельцы вложенных подкаталогов должны соответствовать владельцам родительских каталов
            dirname_is_printed = False

            for filename in files:
                fullfilename = os.path.join(root, filename)
                
                statinfo = os.stat(fullfilename)
                owner = statinfo.st_uid
                group = statinfo.st_gid
                permissions = statinfo.st_mode
                
                if os.path.dirname(fullfilename) in executed_dirs:
                    # Не выводить исполняемые файлы с правами rwxr-xr-x, находящиеся в каталогах с исполняемыми файлами
                    if permissions == 0o100755:
                        continue
                else:
                    # Не выводить неисполняемые файлы с правами rw-r-r-, находящиеся в каталогах с неисполняемыми файлами
                    if permissions == 0o100644 or permissions == 0o100664:
                        continue

                # вывести имя каталога, если ранее оно не выводилось
                # TODO выводить имя, владельца и права
                if not dirname_is_printed:
                    dirname_is_printed = True
                    print(root)
                
                # преобразовать uid и gid в имена владельца и группы
                try:
                    owner_name = pwd.getpwuid(owner)[0]
                    group_name = grp.getgrgid(group)[0]
                
                except KeyError:
                    owner_name = owner
                    group_name = group
                                        
                if args.show_full_paths:
                    print(fullfilename, '{}:{}'.format(owner_name, group_name), stat.filemode(statinfo.st_mode), sep=';')
                else:
                    print(' ' + chr(9500) + filename, '{}:{}'.format(owner_name, group_name), stat.filemode(statinfo.st_mode), sep=';')

        except FileNotFoundError as e:
            pass
            
if __name__ == '__main__':
    main()

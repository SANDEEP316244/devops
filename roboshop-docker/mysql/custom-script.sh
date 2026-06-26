#!/bin/bash

if [ -f /tmp/mysql-root-password.txt ]; then
    PASSWORD=$(cat /tmp/mysql-root-password.txt)
    echo "Accessed MySQL root password"
else
    echo "MySQL Root password file not found"
    exit 1
fi

export MYSQL_ROOT_PASSWORD=$PASSWORD
rm -rf /tmp/mysql-root-password.txt
exec /entrypoint.sh mysqld
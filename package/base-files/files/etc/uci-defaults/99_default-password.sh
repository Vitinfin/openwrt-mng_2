#!/bin/sh

PASSWORD='longstrongpassword'

printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | /bin/passwd root
echo "root password changed to default value" > /dev/kmsg

exit 0

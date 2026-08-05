#!/bin/bash
# k13-launch.sh <name> <ros2 launch args...>   -- detached, logged, pid recorded
name="$1"; shift
exec >/tmp/k13-"$name".log 2>&1
echo $$ > /tmp/k13-"$name".pid
source /root/kennel13-prelude.sh
exec "$@"

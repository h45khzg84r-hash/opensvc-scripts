#!/bin/bash

ACTION="$1"
APP="${0%.sh}"
SCRIPT="${0##*/}"
STATE_FILE="/var/tmp/$SCRIPT.state"

case "$ACTION" in
    start)
        echo "starting $APP"
        echo "up" > "$STATE_FILE"
        exit 0
        ;;

    stop)
        echo "stopping $APP"
        rm -f "$STATE_FILE"
        exit 0
        ;;

    status)
        if [[ -f "$STATE_FILE" ]]; then
            echo "up"
            exit 0
        else
            echo "down"
            exit 1
        fi
        ;;

    monitor)
        # 0 = ok, 1 = warning, 2 = error
        if [[ -f "$STATE_FILE" ]]; then
            echo "monitor ok"
            exit 0
        else
            echo "monitor down"
            exit 2
        fi
        ;;

    *)
        echo "usage: $0 {start|stop|status|monitor}"
        exit 1
        ;;
esac

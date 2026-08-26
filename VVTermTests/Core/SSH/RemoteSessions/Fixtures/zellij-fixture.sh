#!/bin/sh

fixture_root=${VVTERM_ZELLIJ_FIXTURE_DIR:?}
fixture_mode=${VVTERM_ZELLIJ_FIXTURE_MODE:?}

case "$fixture_mode:$1" in
  external:list-sessions)
    printf 'live\nexited\nvvterm-user-created\n'
    ;;
  managed:list-sessions)
    printf 'managed-live\nstray\n'
    ;;
  oversized:list-sessions)
    awk 'BEGIN { for (index = 0; index < 70000; index++) printf "x" }'
    ;;
  too-many:list-sessions)
    index=0
    while [ "$index" -le 256 ]; do
      printf 'session-%s\n' "$index"
      index=$((index + 1))
    done
    ;;
  external:--session)
    if [ "$3" = action ] && [ "$4" = list-panes ]; then
      if [ "$2" = exited ]; then
        printf "Session 'exited' not found. The following sessions are active:\n"
        exit 1
      fi
      printf '[]\n'
    elif [ "$3" = action ] && [ "$4" = list-clients ]; then
      printf 'CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n'
      if [ "$2" = live ]; then printf '1 1 shell\n'; fi
    else
      exit 1
    fi
    ;;
  managed:--session)
    if [ "$3" = action ] && [ "$4" = list-panes ]; then
      printf '[]\n'
    elif [ "$3" = action ] && [ "$4" = list-clients ]; then
      printf 'CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n'
    else
      exit 1
    fi
    ;;
  too-many:--session)
    if [ "$3" = action ] && [ "$4" = list-panes ]; then
      printf '[]\n'
    elif [ "$3" = action ] && [ "$4" = list-clients ]; then
      printf 'CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n'
    else
      exit 1
    fi
    ;;
  creation:--session)
    if [ "$3" = action ] && [ "$4" = list-panes ]; then
      if [ -f "$fixture_root/session" ]; then
        printf '[]\n'
        exit 0
      fi
      printf 'There is no active session!\n'
      exit 1
    fi
    exit 1
    ;;
  creation:--layout-string)
    printf '%s' "$2" >"$fixture_root/layout"
    shift 2
    if [ "$1" != attach ] || [ "$2" != --create-background ]; then exit 1; fi
    printf 'create\n' >>"$fixture_root/creations"
    sleep 0.15
    : >"$fixture_root/session"
    ;;
  creation:attach)
    if [ "$2" = --create-background ]; then
      printf 'create\n' >>"$fixture_root/creations"
      sleep 0.15
      : >"$fixture_root/session"
    fi
    ;;
  *)
    exit 1
    ;;
esac

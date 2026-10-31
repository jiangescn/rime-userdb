#!/bin/sh
set -eu
command -v git >/dev/null 2>&1 || { echo 'Install Git first.' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'Install Python 3.9 or newer first.' >&2; exit 1; }
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -f "$script_dir/rime_sync.py" ]; then
    case "$(uname -s)" in
        Darwin) checkout="$HOME/Library/Application Support/rime-userdb" ;;
        *) checkout="${XDG_DATA_HOME:-$HOME/.local/share}/rime-userdb" ;;
    esac
    if [ -e "$checkout" ]; then
        remote=$(git -C "$checkout" remote get-url origin)
        case "$remote" in
            git@github.com:jiangescn/rime-userdb.git|https://github.com/jiangescn/rime-userdb.git|https://github.com/jiangescn/rime-userdb) ;;
            *) echo 'Existing checkout points to another repository.' >&2; exit 1 ;;
        esac
    else
        git clone git@github.com:jiangescn/rime-userdb.git "$checkout"
    fi
    script_dir=$checkout
fi
exec python3 "$script_dir/rime_sync.py" "$@"

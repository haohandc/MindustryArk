#!/bin/bash
# Run hvigor from git-bash.
#
# WHY THIS SCRIPT EXISTS
#   hvigorw.bat lives under a path containing spaces, and calling it directly
#   from git-bash keeps tripping over quoting -- "a path with a space in it" has
#   cost this project several rounds already. So: call node and hvigorw.js
#   directly, and pass arguments as an ARRAY, which is the only way bash handles
#   space-containing paths reliably.
#
# PATHS
#   Overridable, so a different machine does not have to edit this file. The
#   same variables are read by scripts/config.py, so one export covers both.
#
#     ARK_DEVECO_STUDIO   default: E:/Program Files/DevEco Studio
#     DEVECO_SDK_HOME     default: $ARK_DEVECO_STUDIO/sdk
#     ARK_NODE, ARK_HVIGOR
#
# Usage:
#   bash build.sh assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
set -o pipefail

cd "$(dirname "$0")" || exit 1

STUDIO="${ARK_DEVECO_STUDIO:-E:/Program Files/DevEco Studio}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$STUDIO/sdk}"

# Arrays, not plain strings: an unquoted $VAR holding "E:/Program Files/..."
# gets word-split, the command fails, and the empty pipeline looks like a
# legitimate "nothing matched" result rather than an error.
NODE=("${ARK_NODE:-$STUDIO/tools/node/node.exe}")
HVI=("${ARK_HVIGOR:-$STUDIO/tools/hvigor/bin/hvigorw.js}")

if [ ! -f "${NODE[0]}" ]; then echo "node not found: ${NODE[0]}" >&2; exit 1; fi
if [ ! -f "${HVI[0]}" ]; then echo "hvigorw.js not found: ${HVI[0]}" >&2; exit 1; fi

exec "${NODE[@]}" "${HVI[@]}" "$@"

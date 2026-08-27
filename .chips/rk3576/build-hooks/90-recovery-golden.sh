#!/bin/bash -e

# Golden recovery creation is integrated directly into common/scripts/mk-firmware.sh
# so it runs after firmware links are ready and before update.img is packed.
usage_hook()
{
    :
}

source "${RK_BUILD_HELPER:-$(dirname "$(realpath "$0")")/../../../common/scripts/build-helper}"

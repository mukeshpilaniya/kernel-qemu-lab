#!/bin/bash
# setup-encrypted-kdump.sh
#
# Description:
#   Runs the non-destructive and setup stages in order:
#     01 verify prerequisites
#     02 install packages
#     03 create LUKS2 dump target (KDUMP_LUKS_DEV, or /dev/vdb)
#     04 configure kdump.conf, crypttab, and volume-key link
#     05 rebuild and reload kdump
#     06 pre-crash checks
#
#   Does not panic the machine. After this succeeds, attach a serial
#   console and run:
#     CONFIRM=yes ./07-trigger-crash.sh
#   After reboot:
#     ./08-postcrash-validate.sh
#
# Usage:
#   ./setup-encrypted-kdump.sh
#   KDUMP_LUKS_DEV=/dev/vdb ./setup-encrypted-kdump.sh
#   FORCE=yes ./setup-encrypted-kdump.sh
#
# See kvm-05-guest14-steps.md and readme.md for the full test plan.

set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib/common.sh"
require_root

info "Starting encrypted kdump setup from $DIR"
"$DIR/01-verify-prereqs.sh" || warn "Prerequisite script reported gaps; continuing with install/setup"
"$DIR/02-install-packages.sh"
"$DIR/03-create-luks-target.sh"
"$DIR/04-configure-kdump.sh"
"$DIR/05-rebuild-kdump.sh"
"$DIR/06-precrash-checks.sh"
info "Setup complete. Next: CONFIRM=yes $DIR/07-trigger-crash.sh"

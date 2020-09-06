#!/usr/bin/env sh

set -x
set +e

echo "Starting Gerrit..."
su-exec ${GERRIT_USER} ${GERRIT_SITE}/bin/gerrit.sh ${GERRIT_START_ACTION:-daemon}
RET=$?

echo "Exit $RET"

if [ -n "$DEBUG_GERRIT" ]; then
    echo "Debug Gerrit mode, staying alive"
    tail -f /dev/null
fi

exit $RET


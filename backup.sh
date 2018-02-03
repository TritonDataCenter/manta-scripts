#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2018, Joyent, Inc.
#

#
# Push /var/log/manta/upload/... log files up to Manta.
#

echo        # blank line in log file helps scroll btwn instances
set -o errexit
export PS4='[\D{%FT%TZ}] ${BASHPID}: ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o xtrace

## Environment setup

export PATH=/opt/local/bin:$PATH

## Global variables

# Immutables

SSH_KEY=/root/.ssh/id_rsa
BACKUP_LOCKFILE=/tmp/backup_lockfile

MANTA_KEY_ID=$(ssh-keygen -l -f "$SSH_KEY.pub" | awk '{print $2}')
MANTA_URL=$(json -f /opt/smartdc/common/etc/config.json manta.url)
MANTA_USER=poseidon
rejectUnauthorized=$(json -f /opt/smartdc/common/etc/config.json manta.rejectUnauthorized)
if [[ $rejectUnauthorized == "true" ]]; then
    MANTA_TLS_INSECURE=0
else
    MANTA_TLS_INSECURE=1
fi

AUTHZ_HEADER="keyId=\"/$MANTA_USER/keys/$MANTA_KEY_ID\",algorithm=\"rsa-sha256\""
DIR_TYPE='application/json; type=directory'
LOG_TYPE='text/plain'

# Mutables

NOW=
SIGNATURE=

## Functions

function fail() {
    echo "$@" >&2
    exit 1
}

function sign() {
    NOW=$(date -u "+%a, %d %h %Y %H:%M:%S GMT")
    SIGNATURE=$(echo "date: $NOW" | tr -d '\n' | openssl dgst -sha256 -sign "$SSH_KEY" | openssl enc -e -a | tr -d '\n') \
	|| fail "unable to sign data"
}

# $1 -> lockfile to create
# $$ pid of this script
function create_lockfile() {
    # Creating the tempfile can race, but
    # ln(1) is atomic, so that's the true locking
    # operation
    TEMPFILE="$1.$$"
    LOCKFILE="$1.lock"
    if ! echo $$ > "$TEMPFILE" 2>/dev/null; then
        echo "Unable to write to directory: $(dirname "$TEMPFILE")" >&2
        return 1
    fi

    # Create lock, remove TEMPFILE
    #
    # Use ln(1) to move the temporary file into place because,
    # unlike mv(1), it will fail if the destination existed
    # already.
    if /usr/bin/ln "$TEMPFILE" "$LOCKFILE" 2>/dev/null; then
        /usr/bin/rm -f -- "$TEMPFILE"
        return 0
    fi

    STALE_PID=$(< "$LOCKFILE")
    if [[ ! "$STALE_PID" -gt "0" ]]; then
        /usr/bin/rm -f -- "$TEMPFILE"
        return 1
    fi

    # Test if PID from lockfile is running
    # If it is still running, the function will return here
    if /usr/bin/kill -0 "$STALE_PID" 2>/dev/null; then
        /usr/bin/rm -f -- "$TEMPFILE"
        return 1
    fi

    # PID was stale, remove it, then attempt to create lockfile
    # again
    if /usr/bin/rm "$LOCKFILE" 2>/dev/null; then
        echo "Removed stale lock file of process $STALE_PID"
    fi

    if /usr/bin/ln "$TEMPFILE" "$LOCKFILE" 2>/dev/null; then
        /usr/bin/rm -f -- "$TEMPFILE"
        return 0
    fi

    # Creating lockfile failed, cleanup and error out
    /usr/bin/rm -f -- "$TEMPFILE"
    return 1
}


function manta_put() {
    sign || fail "unable to sign"
    curl -fisSk \
        -X PUT\
        -H "Date: $NOW" \
        -H "Authorization: Signature $AUTHZ_HEADER,signature=\"$SIGNATURE\"" \
        -H "Connection: close" \
        -H "Content-Type: $2" \
        $MANTA_URL/$MANTA_USER/stor$1 $3 || fail "unable to upload $1"
}


# $1 -> service
# $2 -> YYYY/MM/DD/HH
function mkdirp() {
    local year=$(awk -F / '{print $1}' <<<"$2")
    local month=$(awk -F / '{print $2}' <<<"$2")
    local day=$(awk -F / '{print $3}' <<<"$2")
    local hour=$(awk -F / '{print $4}' <<<"$2")

    manta_put "/logs" "$DIR_TYPE"
    manta_put "/logs/$1" "$DIR_TYPE"
    manta_put "/logs/$1/$year" "$DIR_TYPE"
    manta_put "/logs/$1/$year/$month" "$DIR_TYPE"
    manta_put "/logs/$1/$year/$month/$day" "$DIR_TYPE"
    manta_put "/logs/$1/$year/$month/$day/$hour" "$DIR_TYPE"
}


# Cleanup code
function finish {
    # Remove tempfile on exit
    /usr/bin/rm -f -- "$BACKUP_LOCKFILE.$$"
}
trap finish EXIT


## Mainline

# Files look like this:
#     muskie_0db94777-555d-4f1a-a87f-b1e2ee13c025_2012-10-17T21:00:00.log
# And we transform them to this in manta:
#     /poseidon/stor/logs/muskie/2012/10/17/20/0db94777.log

# Do not run if this script is being run already
if ! create_lockfile "$BACKUP_LOCKFILE"; then
    RPID=$(< "$LOCKFILE")
    fail "backup is already running on pid: $RPID"
fi

shopt -s nullglob
for f in /var/log/manta/upload/*.log
do
    service=$(echo "$f" | cut -d _ -f 1 | cut -d / -f 6)
    zone=$(echo "$f" | cut -d _ -f 2 | cut -d - -f 1)
    logtime=$(echo "$f" | cut -d _ -f 3 | sed 's|.log||')
    time=$(date -d \@$(( $(date -d "$logtime" "+%s") - 3600 )) "+%Y/%m/%d/%H")
    key="/logs/$service/$time/$zone.log"
    mkdirp "$service" "$time"
    manta_put "$key" "$LOG_TYPE" "-T $f"
    /usr/bin/rm -- "$f"
done
shopt -u nullglob

# Remove lockfile only if everything succeeded, otherwise it will get cleaned
# up as a stale pid on a following run
/usr/bin/rm -f -- "$BACKUP_LOCKFILE.lock"

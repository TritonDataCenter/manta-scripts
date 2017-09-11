#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2017, Joyent, Inc.
#

###############################################################################
# This script updates all the $REPOS to the latest verion of manta-scripts.
# It will only update repos that:
#   - Exist at ../[repo]
#   - Don't have current, outstanding changes
#
# It will only update the repos that are out of date, so if there are problems
# with repos, you can fix and safely rerun.
###############################################################################

set -o xtrace

REPOS=(
    binder
    electric-moray
    mahi
    manta-madtom
    manta-mako
    manta-manatee
    manta-marlin
    manta-marlin-dashboard
    manta-medusa
    manta-mola
    manta-muskie
    manta-propeller
    manta-wrasse
    moray
    muppet
)
PROBLEMS=( )
DEP_LOC="deps/manta-scripts"

if [ -z "$1" ]; then
    echo "usage: $0 [Jira item for commits]"
    exit 1
fi

JIRA=$1
P=$PWD
if [ $(basename $P) != "manta-scripts" ]; then
    echo "Script must be run from manta-scripts directory"
    exit 1
fi
MS_GIT_SHA=$(git rev-parse HEAD)
MS_GIT_SHA_SHORT=$(git rev-parse --short HEAD)

for repo in "${REPOS[@]}"; do
    # Reset to manta-scripts directory each time
    cd $P

    if [ ! -d "../$repo" ]; then
        PROBLEMS=( "${PROBLEMS[@]}" "$repo" )
        echo "$repo doesn't exist at ../$repo.  Not updating."
        continue
    fi

    echo "Checking $repo..."
    cd "../$repo"
    git pull --rebase
    if [ $? != 0 ]; then
        PROBLEMS=( "${PROBLEMS[@]}" "$repo" )
        echo "Unable to 'git pull --rebase' $repo. Not updating."
        continue
    fi

    REPO_GIT_SHA=$(git submodule status $DEP_LOC | cut -c 2-41)
    if [ "$MS_GIT_SHA" == "$REPO_GIT_SHA" ]; then
        echo "$repo already has latest manta-scripts.  Not updating."
        continue
    fi

    echo "Updating $repo..."
    git submodule init $DEP_LOC
    git submodule update $DEP_LOC
    cd $DEP_LOC
    git pull --rebase
    git checkout $MS_GIT_SHA
    cd -
    git add $DEP_LOC
    git commit -m "$JIRA: Updating to latest manta-scripts ($MS_GIT_SHA_SHORT)"
    echo "Done updating $repo."

done

if [ ${#PROBLEMS[*]} != 0 ]; then
    echo ""
    echo "There were problems updating the following repos:"
    echo "${PROBLEMS[@]}"
else
    echo "All repos up to date."
fi

#Leave you where I found you
cd $P

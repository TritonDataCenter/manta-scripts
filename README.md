<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright 2020 Joyent, Inc.
-->

# manta-scripts

This repository is part of the Joyent Manta project.  For contribution
guidelines, issues, and general documentation, visit the main
[Manta](http://github.com/joyent/manta) project page.

These scripts are used for configuring manta zones and uploading log files.

## Manta zone setup

Recall that most Manta components are deployed as *zones*, based on *images*
built from a single *repo*.  Examples include *muppet* and *muskie*.  The build
and deployment process is described in detail in the main
[manta](https://github.com/joyent/manta) README.  This repo contains parts used
to configure each zone when it's first deployed and on subsequent boots, and
that mechanism is described here.

When Manta zones are deployed (using the Manta deployment tools), they're
provisioned like any other SDC zone.  SDC allows callers to provide a
"user-script", which is an arbitrary script that will be run every time the zone
boots.  The Manta deployment tools provides the same [user script for every
Manta
zone](https://github.com/joyent/sdc-manta/blob/master/scripts/user-script.sh).
That script does the following:

* On first boot, if present, run /opt/smartdc/boot/setup.sh.
* On the first and subsequent boots, if present, run
  /opt/smartdc/boot/configure.sh.

(This is the same way that SDC zones work.)

For a given zone (e.g., "muppet"), the setup.sh and configure.sh scripts are
located in the "boot" directory in that repo.  These scripts typically do a
bunch of things:

* import the SMF manifest for this service and related services
* configure logadm (for log rotation)
* configuring cron (for log rotation and uploading)
* configure rsyslog (for log relaying)
* saving the zone's IP addresses into zone metadata
* configuring monitoring using amon
* configuring the config-agent (which is responsible for subsequent
  configuration of most other components)

Since most Manta zones do basically the same thing at setup and each boot, they
make heavy use of common functions provided in *this* repo.

The way it all fits together is like this:

1. As part of building "muppet", this repo is pulled in as a submodule.  The
   boot/setup.sh and boot/configure.sh in the "muppet" repo wind up in
   /opt/smartdc/boot in the new "muppet" image.  The scripts provided by *this*
   repo are included in the image and sourced by setup.sh and configure.sh.
2. When you deploy a zone from the built image, the user script for the zone
   runs setup.sh (only if it hasn't previously) and then configure.sh (always).

In other words, the code in this repo is common code used by all of the Manta
components.  It's sourced by the boot/setup.sh and boot/configure.sh files in
each of the Manta component repositories.


## Modifying this repository

Note that this repository is used as a git submodule, and once updated, all
repos that have this as a dependency need to be updated or *your changes will
not get picked up*.

### Testing your changes locally

It's strongly recommended to test your changes locally before pushing them
upstream!  (You can also push to a feature branch if you prefer, but it's not
necessarily any easier.)

To test your changes locally, you'll need to follow the instructions in the
[Manta developer guide](https://github.com/joyent/manta/blob/master/docs/developer-guide/) to
build zone images.  Depending on your changes, you may want to test one or all
of the zone images.

Here's one approach for testing changes (mostly) locally.

1. Push your manta-scripts change to a feature branch
   ("dev-JIRA-TICKET-NUMBER").  You won't use the branch, but this makes the SHA
   available in the canonical copy of the repo.
2. In the parent directory of your manta-scripts clone, clone a copy of each of
   the repos listed in the update/repos.sh script in this repository.
3. Run the update script in this repo like so:

    [manta-scripts]$ ./update/repos.sh <Jira Ticket Identifier>

   This script updates the submodule dependency in each of these repos to point
   to your changes.  It commits that change, but does not push it.  If there are
   problems during updates, the script can safely be rerun.
4. Use the instructions in the Manta developer's notes (linked above) to build a
   zone image for whichever of these repos you want to test.  You'll wind up
   modifying MG's targets.json.in to point at all the repos you cloned above.
   You may find it easier to configure MG for building everything rather than
   each repo separately, though you'll have to build the dependencies by hand
   ("make config-agent registrar amon minnow mackerel" should nearly do it.)
5. Test each zone image.
6. When you're satisfied with your changes, push your manta-scripts change to
   the #master branch, then push the submodule update for each of the repos you
   cloned in step 2.

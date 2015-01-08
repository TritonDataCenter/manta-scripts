<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2015, Joyent, Inc.
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
[https://github.com/joyent/manta](manta) README.  This repo contains parts used
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
not get picked up*.  To update, run the update script like so:

    [manta-scripts]$ ./update/repos.sh <Jira Item>

In order for that script to work, you must have all of the manta repos cloned at
../.  The full list can be found in the repos.sh script.  If there are problems
during updates, the script can safely be rerun.

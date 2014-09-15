<!--
    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.
-->

<!--
    Copyright (c) 2014, Joyent, Inc.
-->

# manta-scripts

This repository is part of the Joyent Manta project.  For contribution
guidelines, issues, and general documentation, visit the main
[Manta](http://github.com/joyent/manta) project page.

These scripts are used for configuring manta zones and uploading log files.

Note that this repository is used as a git submodule, and once updated, all
repos that have this as a dependency need to be updated or *your changes will
not get picked up*.  To update, run the update script like so:

    [manta-scripts]$ ./update/repos.sh <Jira Item>

In order for that script to work, you must have all of the manta repos cloned at
../.  The full list can be found in the repos.sh script.  If there are problems
during updates, the script can safely be rerun.

These scripts are used for configuring manta zones and uploading log files.

Note that this repository is used as a git submodule, and once updated, all
repos that have this as a dependency need to be updated or *your changes will
not get picked up*.  To update, run the update script like so:

    [manta-scripts]$ ./update/repos.sh <Jira Item>

In order for that script to work, you must have all of the manta repos cloned at
../.  The full list can be found in the repos.sh script.  If there are problems
during updates, the script can safely be rerun.

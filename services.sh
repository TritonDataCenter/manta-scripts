#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2018, Joyent, Inc.
#

#
# scripts/common/services.sh: common routines for configuring a Manta zone.
# This script is typically included by submodule in each Manta component repo.
# Only a few of the functions contained here are public, and they're invoked by
# the setup script that runs when a Manta zone first boots.
#
# All functions in this file assume that ./util.sh is already sourced and that
# "errexit" is set.
#

#
# manta_setup_config_agent: write out the configuration file for the
# config-agent.
#
function manta_setup_config_agent {
    local prefix=/opt/smartdc/config-agent
    local tmpfile=/tmp/agent.$$.xml

    sed -e "s#@@PREFIX@@#${prefix}#g" \
       ${prefix}/smf/manifests/config-agent.xml > ${tmpfile}
    mv ${tmpfile} ${prefix}/smf/manifests/config-agent.xml

    mkdir -p ${prefix}/etc
    cat >${prefix}/etc/config.json <<EOF
{
    "logLevel": "info",
    "pollInterval": 120000,
    "sapi": {
        "url": "${SAPI_URL}"
    },
    "localManifestDirs": []
}
EOF
}

#
# manta_add_manifest_dir DIRECTORY: update the config-agent configuration to
# include local manifests located under DIRECTORY.
#
function manta_add_manifest_dir {
    local file=/opt/smartdc/config-agent/etc/config.json
    local dir=$1
    local tmpfile=/tmp/add_dir.$$.json

    cat ${file} | json -e "this.localManifestDirs.push('$dir')" >${tmpfile}
    mv ${tmpfile} ${file}
}


#
# manta_download_metadata: Fetch this zone's SAPI metadata and save it to
# the local path $METADATA.
#
function manta_download_metadata {
    local url="$SAPI_URL/configs/$(zonename)"
    local i=0

    while (( i++ < 30 )); do
        #
        # Make sure the temporary files do not exist:
        #
        rm -f "$METADATA.raw"
        rm -f "$METADATA.extracted"

        #
        # Download SAPI configuration for this instance:
        #
        if ! curl -sSf -o "$METADATA.raw" "$url"; then
            warn "could not download SAPI metadata (retrying)"
            sleep 2
            continue
        fi

        #
        # Extract the metadata object from the SAPI configuration:
        #
        if ! json -f "$METADATA.raw" metadata > "$METADATA.extracted"; then
            warn "could not parse SAPI metadata (retrying)"
            sleep 2
            continue
        fi

        #
        # Make sure we did not write an empty file:
        #
        if [[ ! -s "$METADATA.extracted" ]]; then
            fatal "metadata file was empty"
        fi

        #
        # Move the metadata file into place:
        #
        if ! mv "$METADATA.extracted" "$METADATA"; then
            fatal "could not move metadata file into place"
        fi

        rm -f "$METADATA.raw"
        return 0
    done

    fatal "failed to download SAPI configuration (too many retries)"
}

#
# manta_enable_config_agent: Enable this zone's configuration agent (by
# importing its SMF manifest and enabling the service).
#
function manta_enable_config_agent {
    svccfg import /opt/smartdc/config-agent/smf/manifests/config-agent.xml
    svcadm enable -s config-agent
}


#
# manta_setup_amon_agent: run the amon-agent postinstall script to set up
# monitoring for this zone.
#
function manta_setup_amon_agent {
    if [[ -d /opt/amon-agent ]] ; then
        echo "Setting up amon-agent"
        /opt/amon-agent/pkg/postinstall.sh || fatal "unable to setup amon"
    fi
}

#
# manta_setup_common_log_rotation [LOGNAME]: set up cron to rotate logs, and
# then configure log rotation for log files common to all Manta zones.  If
# LOGNAME is not specified, then only the truly common logs will be set up.  If
# LOGNAME is given, then logs in /var/svc/log/*LOGNAME* will also be rotated
# (which are SMF service logs).
#
# This works as follows: logadm is configured to rotate the common service logs
# (i.e., config-agent and registrar) as well as any additional Manta service
# logs (i.e., whatever's installed in this zone, like muskie, mako, or
# whatever).  The rotated logs are dropped into /var/log/manta/upload.  cron is
# configured to run logadm every hour on the hour, so each hour's logs get
# dropped into /var/log/manta/upload at the top of each hour.  Separately, cron
# is configured to run the log uploader script (backup.sh) every hour, which
# uploads any logs it finds in /var/log/manta/upload up to Manta and then
# removes the local copies.  If Manta is down when this happens, the log files
# will remain in /var/log/manta/upload until the next hour when Manta is up, at
# which point they'll be uploaded and then the local copies will be removed.
#
function manta_setup_common_log_rotation {
    echo "Setting up common log rotation entries"

    #
    # Create /var/log/manta/upload, where we store files ready to be uploaded.
    #
    mkdir -p /var/log/manta/upload
    chown root:sys /var/log/manta/upload

    #
    # Copy the log uploader into a place where cron can run it.
    #
    local DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    mkdir -p /opt/smartdc/common/sbin
    cp ${DIR}/backup.sh /opt/smartdc/common/sbin
    chmod 755 /opt/smartdc/common/sbin/backup.sh
    chown root:sys /opt/smartdc/common

    #
    # Ensure that log rotation HUPs *r*syslog.
    #
    logadm -r /var/adm/messages
    logadm -w /var/adm/messages -C 4 -a 'kill -HUP `cat /var/run/rsyslogd.pid`'

    #
    # We want to rotate smf_logs last, so we'll remove it here and re-add it
    # below, in manta_common_setup_end, after all of our other changes.
    # XXX
    #
    logadm -r smf_logs
    logadm -r '/var/log/*.log'
    logadm -r '/var/log/*.debug'

    #
    # Add the logadm configurations for the config-agent and registrar services
    # (which are present in every zone), plus the one we've been given.
    #
    manta_add_logadm_entry "config-agent"
    manta_add_logadm_entry "registrar"
    if [[ $# -ge 1 ]]; then
        manta_add_logadm_entry $1
    fi

    #
    # Finally, update the crontab to invoke logadm hourly (to rotate logs into
    # /var/log/manta/upload) and then to invoke the uploader after that.  We
    # retry the uploader (which is idempotent) a few times in case of transient
    # failures, though if Manta's down for this whole time then we'll end up
    # trying again at the next hour.
    #
    crontab -l > /tmp/.manta_logadm_cron
    echo '0 * * * * /usr/sbin/logadm' >> /tmp/.manta_logadm_cron
    echo '1,2,3,4,5 * * * * /opt/smartdc/common/sbin/backup.sh >> /var/log/mbackup.log 2>&1' \
        >> /tmp/.manta_logadm_cron
    crontab /tmp/.manta_logadm_cron
    rm -f /tmp/.manta_logadm_cron
}

#
# manta_setup_cron: set up the cron service (by importing its SMF manifest and
# enabling the service).
#
function manta_setup_cron {
    echo "Installing cron (and resetting crontab)"
    svccfg import /lib/svc/manifest/system/cron.xml || \
        fatal "unable to import cron"
    svcadm enable cron || fatal "unable to start cron"

    #
    # Set up a crontab based on the current SmartOS default.  The only
    # differences are that we've removed comments and we've removed the logadm
    # entry that fires at 0310Z, since we'll separately configure this to fire
    # every hour on the hour.
    #
    cat <<EOF  > /tmp/.manta_base_cron
15 3 * * 0 /usr/lib/fs/nfs/nfsfind
30 3 * * * [ -x /usr/lib/gss/gsscred_clean ] && /usr/lib/gss/gsscred_clean
1 2 * * * [ -x /usr/sbin/rtc ] && /usr/sbin/rtc -c > /dev/null 2>&1
EOF

    crontab /tmp/.manta_base_cron
    rm -f /tmp/.manta_base_cron
}

#
# manta_setup_registrar: set up the registrar service (by importing its SMF
# manifest and enabling the service).  If the manifest isn't present, do
# nothing.
#
function manta_setup_registrar {
    if [[ -f /opt/smartdc/registrar/smf/manifests/registrar.xml ]] ; then
        svccfg import /opt/smartdc/registrar/smf/manifests/registrar.xml  || \
            fatal "unable to import registrar"
        svcadm enable registrar || fatal "unable to start registrar"
    fi
}

#
# manta_setup_rsyslog SERVICE: sets up a local instance of rsyslogd that logs to
# local files.  The file is put in /var/log/ and named based on SERVICE.
#
# This used to forward logs to a centralized rsyslogd in the ops
# zone, but that was broken for ages and was not dealing properly with log
# growth anyway.  The eventual plan is to remove rsyslog entirely, but the
# current configuration is a stepping stone that doesn't require reconfiguring
# all services at once.
#
# Note that this only sets up UDP and the "standard" Solaris syslog(3C)
# listeners, as TCP has a ridiculous limitation of needing to bind to all NICs.
# The only system that should be using TCP is the centralized one in the ops
# zone, and the only thing using UDP is haproxy.  Everything else should be
# going through the syslog(3C) interface.
#
# Next, note that the Sun syslog(3C) API annoyingly tacks some garbage in your
# message such that you end up with a bunyan message like this:
#
#   [ID 702088 local1.emerg] {"name":"systest","hostname":"martin.local",...}
#
# This configuration works around that with a nifty little regexp before the
# line is written.  With this in place, you can use "bunyan
# /var/log/manta/<service>.log."
#
function manta_setup_rsyslog {
    mkdir -p /var/tmp/rsyslog/work
    chmod 777 /var/tmp/rsyslog/work

    cat > /etc/rsyslog.conf <<"HERE"
$MaxMessageSize 64k

$ModLoad immark
$ModLoad imsolaris
$ModLoad imudp

$template bunyan,"%msg:R,ERE,1,FIELD:(\{.*\})--end%\n"

*.err;kern.notice;auth.notice			/dev/sysmsg
*.err;kern.debug;daemon.notice;mail.crit	/var/adm/messages
*.alert;kern.err;daemon.err			operator
*.alert						root
*.emerg						*
mail.debug					/var/log/syslog
auth.info					/var/log/auth.log
mail.info					/var/log/postfix.log

$WorkDirectory /var/tmp/rsyslog/work
$ActionQueueType Direct
$ActionQueueFileName mantafwd
$ActionResumeRetryCount -1
$ActionQueueSaveOnShutdown on

HERE

    cat >> /etc/rsyslog.conf <<HERE
#
# This is where we used to configure services to relay logs to the ops zone.
# Eventually, we'll just rip out rsyslog completely.
#
# Uncomment the following line to get local logs via syslog.
# local0.*    /var/log/$1.log;bunyan
#
# This was at one time used for HAProxy, but anything could use it and get local
# logs via syslog.
local1.*    /var/log/$1.log

HERE

    cat >> /etc/rsyslog.conf<<"HERE"
$UDPServerAddress 127.0.0.1
$UDPServerRun 514

HERE

    svcadm restart system-log
    [[ $? -eq 0 ]] || fatal "Unable to restart rsyslog"
}

#
# manta_common_presetup: entry point invoked by the actual setup scripts to
# trigger pre-setup actions defined in this file.
#
function manta_common_presetup {
    manta_setup_config_agent
}

#
# manta_common_setup SERVICE_NAME [SKIP_LOGROTATE]: entry point invoked by the
# actual setup scripts to trigger setup actions defined in this file.
# SERVICE_NAME is used for naming log files.  (Note that some programmatic
# configuration based on the service is hardcoded here, so don't change service
# names without checking the code below.)  If SKIP_LOGROTATE is not specified or
# is 0, then log rotation is configured for both common services and the service
# called SERVICE_NAME.  If SKIP_LOGROTATE is specified and is non-zero, then log
# rotation is only configured for the common services.
#
function manta_common_setup {
    manta_clear_dns_except_sdc
    manta_download_metadata
    manta_enable_config_agent
    manta_setup_cron
    manta_setup_amon_agent
    manta_setup_registrar
    if [[ $# -eq 1 ]] || [[ $# -ge 2 ]] && [[ "$2" -eq 0 ]]
    then
        manta_setup_common_log_rotation $1
    else
        manta_setup_common_log_rotation
    fi

    #
    # There are a few hacks here:
    #
    # 1. For the "binder" zone, we want to skip DNS configuration because it's
    #    the DNS server and we'd have infinite recursion on any misses.
    #
    # 2. For the "mola" zone (which is the "ops" zone), we want to skip the
    #    usual rsyslog configuration because that zone is setup as a relay
    #    target.
    #
    # These are regrettable.
    #
    if [[ "$1" != "binder" ]]; then
        manta_update_dns

        if [[ "$1" != "mola" ]]; then
            manta_setup_rsyslog "$1"
        fi
    fi

    manta_update_env

    # Setup NDD tunings
    ipadm set-prop -t -p max_buf=2097152 tcp || true
    /usr/sbin/ndd -set /dev/tcp tcp_conn_req_max_q 2048
    /usr/sbin/ndd -set /dev/tcp tcp_conn_req_max_q0 8192
}

#
# manta_common_setup_end: entry point invoked by the actual setup scripts to
# trigger setup actions that should come after main setup actions.
#
function manta_common_setup_end {
    logadm -w mbackup -C 3 -c -s 1m '/var/log/mbackup.log'
    logadm -w smf_logs -C 3 -c -s 1m '/var/svc/log/*.log'

    # XXX intentionally don't restore the *.debug entry
    logadm -w '/var/log/*.log' -C 2 -c -s 5m
}

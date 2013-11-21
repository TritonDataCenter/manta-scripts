#
# Copyright (c) 2013, Joyent, Inc. All rights reserved.
#
# scripts/common/services.sh: common routines for configuring a Manta zone
#
#
# -*- mode: shell-script; fill-column: 80; -*-

# All functions in this file assume that ./util.sh is already sourced


# Write out the config-agent's file
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
    "pollInterval": 10000,
    "sapi": {
        "url": "${SAPI_URL}"
    },
    "localManifestDirs": []
}
EOF
}


# Add a directory in which to search for local config manifests
function manta_add_manifest_dir {
    local file=/opt/smartdc/config-agent/etc/config.json
    local dir=$1

    local tmpfile=/tmp/add_dir.$$.json

    cat ${file} | json -e "this.localManifestDirs.push('$dir')" >${tmpfile}
    mv ${tmpfile} ${file}
}


# Upload the IP addresses assigned to this zone into its metadata
function manta_upload_metadata_values {
    local update=/opt/smartdc/config-agent/bin/mdata-update

    # Let's assume a zone will have at most four NICs
    for i in $(seq 0 3); do
        local ip=$(mdata-get sdc:nics.${i}.ip)
        [[ $? -eq 0 ]] || ip=""
        local tag=$(mdata-get sdc:nics.${i}.nic_tag)
        [[ $? -eq 0 ]] || tag=""

        # Want tag name to be uppercase
        tag=$(echo ${tag} | tr 'a-z' 'A-Z')

        if [[ -n ${ip} && -n ${tag} ]]; then
            ${update} ${tag}_IP ${ip}

            if [[ $i == 0 ]]; then
                ${update} PRIMARY_IP ${ip}
            fi
        fi
    done

    local datacenter=$(mdata-get sdc:datacenter_name)
    [[ $? -eq 0 ]] && ${update} DATACENTER ${datacenter}
}


# Download this zone's SAPI metadata and save it in a local file
function manta_download_metadata {
    curl -s ${SAPI_URL}/configs/$(zonename) | json metadata > ${METADATA}

    if [[ $? -ne 0 ]]; then
        fatal "failed to download metadata from SAPI"
    fi
}


# Import and enable the config-agent
function manta_enable_config_agent {
    local prefix=/opt/smartdc/config-agent

    # Write configuration synchronously
    ${prefix}/build/node/bin/node ${prefix}/agent.js -s

    svccfg import ${prefix}/smf/manifests/config-agent.xml
    svcadm enable config-agent
}


# Simply runs the amon-agent postinstaller
function manta_setup_amon_agent {
    if [[ -d /opt/amon-agent ]] ; then
	echo "Setting up amon-agent"
	/opt/amon-agent/pkg/postinstall.sh || fatal "unable to setup amon"
    fi
}


# Sets up log rotation entries (and cron) for all the common services that
# run in every manta zone, plus takes an argument for the "primary" service name
# of the current zone
function manta_setup_common_log_rotation {
    echo "Setting up common log rotation entries"

    mkdir -p /opt/smartdc/common/sbin
    mkdir -p /var/log/manta/upload

    local DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

    cp ${DIR}/backup.sh /opt/smartdc/common/sbin
    chmod 755 /opt/smartdc/common/sbin/backup.sh

    chown root:sys /var/log/manta/upload
    chown root:sys /opt/smartdc/common

    # Ensure that log rotation HUPs *r*syslog.
    logadm -r /var/adm/messages
    logadm -w /var/adm/messages -C 4 -a 'kill -HUP `cat /var/run/rsyslogd.pid`'

    # Move the smf_logs entry to run last
    logadm -r smf_logs

    manta_add_logadm_entry "config-agent"
    manta_add_logadm_entry "registrar"
    if [[ $# -ge 1 ]]; then
	manta_add_logadm_entry $1
    fi

    crontab -l > /tmp/.manta_logadm_cron
    echo '0 * * * * /usr/sbin/logadm' >> /tmp/.manta_logadm_cron
    # We just want this to keep retrying every minute - boxes may
    echo '1,2,3,4,5 * * * * /opt/smartdc/common/sbin/backup.sh >> /var/log/mbackup.log 2>&1' \
	>> /tmp/.manta_logadm_cron
    crontab /tmp/.manta_logadm_cron
    rm -f /tmp/.manta_logadm_cron
}


function manta_setup_cron {
    echo "Installing cron (and resetting crontab)"
    svccfg import /lib/svc/manifest/system/cron.xml || \
	fatal "unable to import cron"
    svcadm enable cron || fatal "unable to start cron"

# This is the default cron on SunOS ... ish. Extra 'logadm' at 3:10am
# removed. See MANTA-700.
    cat <<EOF  > /tmp/.manta_base_cron
#
#
#
15 3 * * 0 /usr/lib/fs/nfs/nfsfind
30 3 * * * [ -x /usr/lib/gss/gsscred_clean ] && /usr/lib/gss/gsscred_clean
#
# The rtc command is run to adjust the real time clock if and when
# daylight savings time changes.
#
1 2 * * * [ -x /usr/sbin/rtc ] && /usr/sbin/rtc -c > /dev/null 2>&1
EOF

    crontab /tmp/.manta_base_cron
    rm -f /tmp/.manta_base_cron
}


function manta_setup_registrar {
    if [[ -f /opt/smartdc/registrar/smf/manifests/registrar.xml ]] ; then
	svccfg import /opt/smartdc/registrar/smf/manifests/registrar.xml  || \
	    fatal "unable to import registrar"
	svcadm enable registrar || fatal "unable to start registrar"
    fi
}


# Sets up a local instance of rsyslogd that forwards to a centralized rsyslogd
# on the ops host. Note that this only sets up UDP and the "standard" Solaris
# syslog(3C) listeners, as TCP has a ridiculous limitation of needing to bind
# to all NICs.  At any rate, the only system that should be using TCP is the
# centralized one anyway. And the only thing using UDP is haproxy - everything
# else should be going through the syslog(3C) interface.
#
# Next, note that the sun syslog(3C) api annoyingly tacks some shit in your msg
# such that you end up with a bunyan msg like:
# [ID 702088 local1.emerg] {"name":"systest","hostname":"martin.local",...}
#
# So this configuration works around that with a nifty little regexp before the
# line is written, so you can always do a bunyan /var/log/manta/<service>.log.
#
# Argument 1 is the name of the current service, so we route to a sane log file
# in /var/log
#
function manta_setup_rsyslog {
    local domain_name=$(json -f ${METADATA} domain_name)
    [[ $? -eq 0 ]] || fatal "Unable to domain name from metadata"

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

# Support node bunyan logs going to local0 and forwarding
# only as logs are already captured via SMF
# Uncomment the following line to get local logs via syslog
# local0.*    /var/log/$1.log;bunyan
local0.* @@ops.$domain_name:10514

# This is typically for HAProxy, but anything could use it
# and get local logs via syslog
local1.*    /var/log/$1.log
local1.* @@ops.$domain_name:10514

HERE

    cat >> /etc/rsyslog.conf<<"HERE"
$UDPServerAddress 127.0.0.1
$UDPServerRun 514

HERE

    svcadm restart system-log
    [[ $? -eq 0 ]] || fatal "Unable to restart rsyslog"
}

function manta_common_presetup {
    manta_setup_config_agent
}

# If argument 1 is an integer = 0, then log rotation is skipped
function manta_common_setup {
    manta_upload_metadata_values
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

    # Hack, but it's the only one we want to skip DNS on,
    # seeing as it is the DNS server, and we'll have infinite
    # recursion on any misses. MANTA-913: and syslog
    if [[ "$1" != "binder" ]]
    then
	manta_update_dns

	# We don't set up rsyslog for the ops zone, as that zone
	# does its own setup for relay
	if [[ "$1" != "mola" ]]
	then
	    manta_setup_rsyslog "$1"
	fi

    fi
    manta_update_env

    # Setup NDD tunings
    ipadm set-prop -t -p max_buf=2097152 tcp || true
    /usr/sbin/ndd -set /dev/tcp tcp_conn_req_max_q 2048
    /usr/sbin/ndd -set /dev/tcp tcp_conn_req_max_q0 8192
}


function manta_common_setup_end {
    logadm -w mbackup -C 3 -c -s 1m '/var/log/mbackup.log'
    logadm -w smf_logs -C 3 -c -s 1m '/var/svc/log/*.log'
}

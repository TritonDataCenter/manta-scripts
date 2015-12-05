# -*- mode: shell-script; fill-column: 80; -*-
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2015, Joyent, Inc.
#

#
# scripts/common/util.sh: common routines for configuring a Manta zone.  This
# script is typically included by submodule in each Manta component repo.
#

#
# The zone's metadata is downloaded from SAPI and saved in this file.
#
export METADATA=/var/tmp/metadata.json
export SAPI_URL=$(mdata-get SAPI_URL)

#
# fatal MESSAGE ...: dump MESSAGE to stderr and exit as a failure
#
function fatal {
    echo "$(basename $0): fatal error: $*" >&2
    exit 1
}

#
# warn MESSAGE ...: dump MESSAGE to stderr but do not exit
#
function warn {
    echo "$(basename $0): WARNING: $*" >&2
}

#
# manta_add_logadm_entry PATTERN [LOGDIR [MATCH-MODE]]: creates an entry in
# /etc/logadm.conf for hourly log rotation of files matching PATTERN in LOGDIR.
# Logs are rotated into /var/log/manta and eventually uploaded back to Manta.
# See services.sh for details on how this works.
#
# If LOGDIR is not specified, it defaults to /var/svc/log.
#
# By default, we'll use a fuzzy match (all files matching $LOGDIR/*$PATTERN*)
# and concatenate all matching files.  If MATCH-MODE is "exact", then we'll only
# match $LOGDIR/$PATTERN.
#
function manta_add_logadm_entry {
    [[ $# -ge 1 ]] || fatal "add_logadm_entry requires at least 1 argument"

    local logdir="/var/svc/log"
    if [[ $# -ge 2 ]]; then
	logdir="$2"
    fi
    local pattern="$logdir/*$1*.log"
    if [[ $# -ge 3 ]] && [[ $3 == "exact" ]]; then
        pattern="$logdir/$1.log"
    fi
    logadm -w $1 -C 48 -c -p 1h \
        -t "/var/log/manta/upload/$1_\$nodename_%FT%H:00:00.log" \
        "$pattern" || fatal "unable to create logadm entry"
}

#
# manta_ensure_manatee: waits up to about 90 seconds for the zookeeper cluster
# to come online and for the local manatee cluster to come online.  It's a fatal
# error if this doesn't happen within the alloted timeout.
#
function manta_ensure_manatee {
    local attempt=0
    local isok=0
    local pgok
    local zkok

    local zonename=$(zonename)

    local svc_name=$(json -f ${METADATA} SERVICE_NAME)
    local zk_ips=$(json -f ${METADATA} ZK_SERVERS | json -a host)

    if [[ $? -ne 0 ]]; then
	zk_ips=127.0.0.1
    fi

    while [[ $attempt -lt 90 ]]; do
	for ip in $zk_ips; do
	    zkok=$(echo "ruok" | nc -w 1 $ip 2181)
	    if [[ $? -eq 0 ]] && [[ "$zkok" == "imok" ]]; then
		pgip=$(/opt/smartdc/moray/node_modules/.bin/manatee-stat \
		    -s $svc_name $ip | json primary.ip)
		if [[ $? -eq 0 ]] && [[ -n "$pgip" ]]; then
		    isok=1
		    break
		fi
	    fi
	done

	if [[ $isok -eq 1 ]]; then
	    break
	fi

	let attempt=attempt+1
	sleep 1
    done
    [[ $isok -eq 1 ]] || fatal "manatee is not up"
}

#
# manta_ensure_moray MORAY_HOST: waits up to about 90 seconds for a moray shard
# to come online.  It's a fatal error if this doesn't happen within the allotted
# timeout.
#
function manta_ensure_moray {
    [[ $# -ge 1 ]] || fatal "manta_ensure_moray requires at least 1 argument"

    local attempt=0
    local now
    local isok=0

    while [[ $attempt -lt 90 ]]; do
	now=$(sql -h $1 -p 2020 'select now();' | json now)
	if [[ $? -eq 0 ]] && [[ -n "$now" ]]; then
	    isok=1
	    break
	fi

	let attempt=attempt+1
	sleep 1
    done
    [[ $isok -eq 1 ]] || fatal "moray $1 is not up"
}

#
# manta_ensure_zk: waits up to about 60 seconds for the local Zookeeper cluster
# to come online.  It's a fatal error if this doesn't happen within the allotted
# timeout.
#
function manta_ensure_zk {
    local attempt=0
    local isok=0
    local zkok

    local zonename=$(zonename)

    local zk_ips=$(json -f ${METADATA} ZK_SERVERS | json -a host)
    if [[ $? -ne 0 ]]; then
	zk_ips=127.0.0.1
    fi

    while [[ $attempt -lt 60 ]]; do
	for ip in $zk_ips; do
	    zkok=$(echo "ruok" | nc -w 1 $ip 2181)
	    if [[ $? -eq 0 ]] && [[ "$zkok" == "imok" ]]; then
		isok=1
		break
	    fi
	done

	if [[ $isok -eq 1 ]]; then
	    break
	fi

	let attempt=attempt+1
	sleep 1
    done
    [[ $isok -eq 1 ]] || fatal "ZooKeeper is not running"
}


#
# manta_clear_dns_except_sdc: reconfigure DNS.  If the external network is the
# primary network for this zone, external DNS servers will be first in the list
# of resolvers.  As this zone is setting up, the config-agent can't resolve the
# SAPI hostname (e.g. "sapi.coal.joyent.us") and zone setup will fail.
#
# Here, remove all resolvers but the SDC resolver so setup can finish
# appropriately.  The config-agent will rewrite the /etc/resolv.conf file with
# the proper resolvers later, so this just allows that agent to discover and
# download the appropriate zone configuration.
#
function manta_clear_dns_except_sdc {
    if [[ -z $SAPI_URL ]]; then
        fatal "SAPI_URL not set"
    fi
    local sapi_hostname=$(basename $SAPI_URL)
    if [[ -z $sapi_hostname ]] || [[ $sapi_hostname != *sapi* ]]; then
        fatal "$sapi_hostname isn't recognizable as sapi"
    fi
    local sdc_resolver=''
    local resolvers=$(cat /etc/resolv.conf | grep nameserver | \
        cut -d ' ' -f 2 | tr '\n' ' ')
    for resolver in $resolvers; do
        local sapi_ip;
        sapi_ip=$(dig @$resolver $sapi_hostname +short)
        if [[ $? != 0 ]]; then
            echo "$resolver was unavailable to resolve $sapi_hostname"
            continue
        fi
        if [[ -n "$sapi_ip" ]]; then
            sdc_resolver="$resolver"
            break
        else
            echo "$resolver did not resolve $sapi_hostname"
        fi
    done
    if [[ -z "$sdc_resolver" ]]; then
        fatal "No resolvers were able to resolve $sapi_hostname"
    fi

    cat /etc/resolv.conf | grep -v nameserver > /tmp/resolv.conf
    echo "nameserver $sdc_resolver" >> /tmp/resolv.conf
    mv /tmp/resolv.conf /etc/resolv.conf
}

#
# manta_update_dns:  This used to configure /etc/resolv.conf, but this
# placeholder remains only to satisfy consumers still calling it.
#
function manta_update_dns {
    return 0
}

#
# manta_update_env: updates the $HOME directory of the root user to have various
# useful tools in their PATH and several useful aliases configured.  This
# requires the global varaible SVC_ROOT to be set (from which we acquire node).
#
function manta_update_env {
    echo "Updating ~/.bashrc (and environment)"

    local RC=/root/.bashrc

    #
    # First create the default skeleton entry.  We rewrite this every time,
    # or it keeps getting appended to on reboot.
    #
    echo "" > /root/.bashrc
    echo 'if [ "$PS1" ]; then' >> $RC
    echo '  shopt -s checkwinsize cdspell extglob histappend' >> $RC
    echo "  alias ll='ls -lF'" >> $RC
    echo '  HISTCONTROL=ignoreboth' >> $RC
    echo '  HISTIGNORE="[bf]g:exit:quit"' >> $RC
    echo '  PS1="[\u@\h \w]\\$ "' >> $RC
    echo '  if [ -n "$SSH_CLIENT" ]; then' >> $RC
    echo -n "    PROMPT_COMMAND=" >> $RC
    echo -n "'echo -ne " >> $RC
    echo -n '\033]0;${HOSTNAME%%\.*} \007" && history -a' >> $RC
    echo "'" >> $RC
    echo "  fi" >> $RC
    echo "fi" >> $RC

    #
    # Now write the stuff we care about, starting with $PATH.
    #
    echo "export PATH=$SVC_ROOT/build/node/bin:$SVC_ROOT/node_modules/.bin:/opt/smartdc/configurator/bin:/opt/local/bin:\$PATH" >> $RC

    local hostname=`hostname | cut -c1-8`
    local role=$(mdata-get sdc:tags.manta_role)
    if [[ $? -ne 0 ]]; then
        role="unknown"
    fi

    echo "export PS1=\"[\\u@$hostname ($role) \\w]$ \"" >> $RC
    echo "alias bunyan='bunyan --color'" >> $RC
    echo "alias less='less -R'" >> $RC

    #
    # The SSH key will already be there (written by the config-agent).  Just
    # update its permissions.
    #
    if [[ -f /root/.ssh/id_rsa ]]; then
        chmod 600 /root/.ssh/id_rsa
    fi

    local manta_url=$(json -f ${METADATA} MANTA_URL)
    [[ $? -eq 0 ]] || fatal "Unable to retrieve MANTA_URL from metadata"

    echo "export MANTA_USER=poseidon" >> /root/.bashrc
    echo "export MANTA_KEY_ID=\$(ssh-keygen -l -f /root/.ssh/id_rsa.pub | awk '{print \$2}')" >> /root/.bashrc
    echo "export MANTA_URL=$manta_url" >> /root/.bashrc
    local manta_tls_insecure=$(json -f ${METADATA} MANTA_TLS_INSECURE)
    echo "export MANTA_TLS_INSECURE=$manta_tls_insecure" >> /root/.bashrc

    echo "alias js2json='node -e '\''s=\"\"; process.stdin.resume(); process.stdin.on(\"data\",function(c){s+=c}); process.stdin.on(\"end\",function(){o=eval(\"(\"+s+\")\");console.log(JSON.stringify(o)); });'\'''" >> /root/.bashrc
}

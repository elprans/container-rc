# Common container-rc functions.

docker_bin=${docker_bin:-/usr/bin/docker}
rkt_bin=${rkt_bin:-/usr/bin/rkt}


if [ x$RC_GOT_FUNCTIONS = xyes -o -n "$(command -v ebegin 2>/dev/null)" ]; then
    :

# Then check for the presence of functions.sh
elif [ -f /lib/gentoo/functions.sh ]; then
    . /lib/gentoo/functions.sh

else
    echo "/lib/gentoo/functions.sh not found. Exiting"
    exit 1
fi


_docker_opts() {
	local _opts="" _opt=$1 _var="docker_${2}"

	for var in ${!_var}; do
		_opts="${_opts} ${_opt}=${var}"
	done

	echo ${_opts}
}


_docker_init() {
	mkdir -p /run/dockerized
}


_docker_cid() {
	if [ -e "/run/dockerized/${RC_CONTAINER}" ]; then
		cat "/run/dockerized/${RC_CONTAINER}"
	fi
}


_docker_check_running() {
	local cid=$(_docker_cid)

	if [ -n "${cid}" ]; then
		if "${docker_bin}" ps | grep "${cid}" >/dev/null; then
			ewarn ""
			ewarn "Docker reports ${RC_CONTAINER} as running."
			ewarn "Please shut it down using"
			ewarn "    docker stop ${RC_CONTAINER} && docker rm ${RC_CONTAINER}"

			return 1
		fi
	fi
}


_docker_run() {
	local opts=$1
	local cmd=$2
	local extraopts=""
	local cid
	local status
	local docker_stderr
	local net
	local net_extraopts=""

	if [ "${docker_net}" == "public" ]; then
		if [ -z "${docker_net_gw}" ]; then
			eerror "You must specify docker_net_gw for docker_net=public"
		fi

		if [ -z "${docker_net_addr}" ]; then
			eerror "You must specify docker_net_addr for docker_net=public"
		fi

		if [ -z "${docker_net_bridge}" ]; then
			eerror "You must specify docker_net_bridge for docker_net=public"
		fi

		extraopts="$extraopts -e \"_NET_GW=${docker_net_gw}\" \
							  -e \"_NET_ADDR=${docker_net_addr}\" \
							  -e \"_NET_BRIDGE=${docker_net_bridge}\""
	fi

	if [ -n "${docker_hostname}" ]; then
		extraopts="${extraopts} -h ${docker_hostname}"
	fi

	if [ -n "${docker_privileged}" ]; then
		extraopts="${extraopts} --privileged"
	fi

	echo "${docker_bin}" run --name="${RC_CONTAINER}" $opts \
			$(_docker_opts --env env) \
			$(_docker_opts -p ports) \
			$(_docker_opts -v volumes) \
			${extraopts} \
			"${docker_image}" \
			$cmd \
	| logger -i -t "/etc/init.d/${RC_CONTAINER}" -p daemon.info

	docker_stderr=$("${docker_bin}" run --name="${RC_CONTAINER}" $opts \
			 $(_docker_opts --env env) \
			 $(_docker_opts -p ports) \
			 $(_docker_opts -v volumes) \
			 ${extraopts} \
			 "${docker_image}" \
			 $cmd 2>&1 1>/dev/null)

	status=$?

	if [ "$status" -ne "0" ]; then
		echo $docker_stderr | logger -is -t "/etc/init.d/${RC_CONTAINER}" -p daemon.err

		"${docker_bin}" stop "${RC_CONTAINER}" 2>/dev/null
		"${docker_bin}" rm "${RC_CONTAINER}" 2>/dev/null

		return $status
	fi

	if [ "${docker_net}" == "public" ]; then
		/usr/sbin/pipework ${docker_net_bridge} ${docker_net_addr}
	fi

	if [ -n "${docker_networks}" ]; then
		if [ -n "${docker_dns_alias}" ]; then
			net_extraopts="${net_extraopts} --alias ${docker_dns_alias}"
		fi

		for net in ${docker_networks}; do
			docker network connect ${net_extraopts} "${net}" "${RC_CONTAINER}"
		done
	fi

	cid=$(docker inspect --format {{.Id}} ${RC_CONTAINER})

	if [ -z "${cid}" ]; then
		eerror "RC_CONTAINER seems to have died.  Check logs for details."
		return 1
	fi

	echo "${cid}"
}


_docker_enter() {
    local cid=$(_docker_cid) pid

    if [ -n "${cid}" ]; then
        pid=$(docker inspect --format {{.State.Pid}} "${cid}")

        if [ -z "${pid}" ]; then
            ewarn ""
            ewarn "${RC_CONTAINER} does not seem to be running."
            ewarn ""
            return 1
        fi

        /usr/bin/nsenter --mount --uts --ipc --net --pid \
            --target $pid -- /bin/bash -l
    else
        ewarn ""
        ewarn "${RC_CONTAINER} does not seem to be running."
        ewarn ""
        return 1
    fi
}


_docker_stop() {
	local cid=$(_docker_cid)

	if [ -n "${cid}" ]; then
		"${docker_bin}" stop ${cid} >/dev/null && docker rm ${cid} >/dev/null
	else
		ewarn ""
		ewarn "${RC_CONTAINER} does not seem to be running."
		ewarn ""
		return 1
	fi

	eend $?
}


_rkt_mounts() {
	local opts="" var="docker_${1}" volname src tgt

	for mount in ${!var}; do
        src="${mount%:*}"
        tgt="${mount#*:}"
        volname="${tgt#/}"
        volname="${volname%/}"
        volname="${volname////-}"
        opts="${opts} --volume ${volname},kind=host,source=${src}"
        opts="${opts} --mount volume=${volname},target=${tgt}"
    done

    echo ${opts}
}


_rkt_ports() {
	local opts="" var="docker_${1}"

	for port in ${!var}; do
        hostport="${port%:*}"
        ctrport="${port##*:}"
        host="${hostport%:*}"
        hostport="${hostport#*:}"
        if [ -n "${host}" ]; then
            portspec="${ctrport}-tcp:${host}:${hostport}"
        else
            portspec="${ctrport}-tcp:${hostport}"
        fi
        opts="${opts} --port=${portspec}"
    done

    echo ${opts}
}


_rkt_run() {
	local opts=$1
	local cmd=$2
	local extraopts=""

	if [ -n "${docker_hostname}" ]; then
		extraopts="${extraopts} --hostname ${docker_hostname}"
	fi

    set -- "${rkt_bin}" fetch \
        --insecure-options=image --pull-policy=new "docker://${docker_image}"
    echo "$@"
    "$@" || return 1

    set -- "${rkt_bin}" run \
            --insecure-options=image \
            "docker://${docker_image}" \
            --name="${RC_CONTAINER}" $opts \
			$(_docker_opts --set-env env) \
			$(_docker_opts --net networks) \
			$(_rkt_ports ports) \
			$(_rkt_mounts volumes) \
			${extraopts} \
            -- $cmd

    echo "$@"
    exec "$@"
}

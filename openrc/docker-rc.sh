#!/sbin/openrc-run
# Copyright 1999-2017 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

extra_commands="debug enter shell upgrade"

docker_bin=${docker_bin:-/usr/bin/docker}


depend() {
	need net docker
}


_docker_opts() {
	local _env="" _opt=$1 _var="docker_${2}"

	for var in ${!_var}; do
		_env="${_env} ${_opt} ${var}"
	done

	echo ${_env}
}


_init() {
	if [ ! -d /run/dockerized ]; then
		mkdir /run/dockerized
	fi
}


_cid() {
	if [ -e "/run/dockerized/${SVCNAME}" ]; then
		cat "/run/dockerized/${SVCNAME}"
	fi
}


_checkrunning() {
	local cid=$(_cid)

	if [ -n "${cid}" ]; then
		if "${docker_bin}" ps | grep "${cid}" >/dev/null; then
			ewarn ""
			ewarn "Docker reports ${SVCNAME} as running."
			ewarn "Please shut it down using"
			ewarn "    docker stop ${SVCNAME} && docker rm ${SVCNAME}"

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

	echo "${docker_bin}" run --name="${SVCNAME}" $opts \
			$(_docker_opts --env env) \
			$(_docker_opts -p ports) \
			$(_docker_opts -v volumes) \
			${extraopts} \
			"${docker_image}" \
			$cmd \
	| logger -i -t "/etc/init.d/${SVCNAME}" -p daemon.info

	docker_stderr=$("${docker_bin}" run --name="${SVCNAME}" $opts \
			 $(_docker_opts --env env) \
			 $(_docker_opts -p ports) \
			 $(_docker_opts -v volumes) \
			 ${extraopts} \
			 "${docker_image}" \
			 $cmd 2>&1 1>/dev/null)

	status=$?

	if [ "$status" -ne "0" ]; then
		echo $docker_stderr | logger -is -t "/etc/init.d/${SVCNAME}" -p daemon.err

		"${docker_bin}" stop "${SVCNAME}" 2>/dev/null
		"${docker_bin}" rm "${SVCNAME}" 2>/dev/null

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
			docker network connect ${net_extraopts} "${net}" "${SVCNAME}"
		done
	fi

	cid=$(docker inspect --format {{.Id}} ${SVCNAME})

	if [ -z "${cid}" ]; then
		eerror "Container seems to have died.  Check logs for details."
		return 1
	fi

	echo "${cid}"
}


start() {
	_init && _checkrunning || return 1

	ebegin "Starting dockerized ${SVCNAME}"

	_docker_run "-i -d" "${docker_command}" > "/run/dockerized/${SVCNAME}"

	eend $?
}


debug() {
	_init && _checkrunning || return 1

	_docker_run "-i -t --rm"
}


shell() {
	_init && _checkrunning || return 1

	_docker_run "-i -t --rm" "/bin/bash -l"
}


upgrade() {
	_init && _checkrunning || return 1

	_docker_run "-i -t --rm" "upgrade"
}


enter() {
	local cid=$(_cid) pid

	if [ -n "${cid}" ]; then
		pid=$(docker inspect --format {{.State.Pid}} "${cid}")

		if [ -z "${pid}" ]; then
			ewarn ""
			ewarn "${SVCNAME} does not seem to be running."
			ewarn ""
			return 1
		fi

		/usr/bin/nsenter --mount --uts --ipc --net --pid \
						 --target $pid -- /bin/bash -l
	else
		ewarn ""
		ewarn "${SVCNAME} does not seem to be running."
		ewarn ""
		return 1
	fi
}


stop() {
	ebegin "Stopping dockerized ${SVCNAME}"

	local cid=$(_cid)

	if [ -n "${cid}" ]; then
		"${docker_bin}" stop ${cid} >/dev/null && docker rm ${cid} >/dev/null
	else
		ewarn ""
		ewarn "${SVCNAME} does not seem to be running."
		ewarn ""
		return 1
	fi

	eend $?
}

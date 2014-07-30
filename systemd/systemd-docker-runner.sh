#!/bin/bash


docker_bin=${docker_bin:-/usr/bin/docker}

_docker_opts() {
	local _env _opt=$1 _var="docker_${2}"

	for var in ${!_var}; do
		_env="${_env} ${_opt} ${var}"
	done

	echo ${_env}
}


_cid() {
	if [ -e "/run/dockerized/$1" ]; then
		cat "/run/dockerized/$1"
	fi
}


_docker_start() {
	local name=$1 opts=$2 cmd=$3 extraopts="" cid status docker_stderr

	mkdir -p /run/dockerized

	if [ -n "${docker_hostname}" ]; then
		extraopts="${extraopts} -h ${docker_hostname}"
	fi

	echo "${docker_bin}" run --name="${name}" $opts \
			$(_docker_opts -e env) \
			$(_docker_opts -p ports) \
			$(_docker_opts -v volumes) \
			--cidfile="/run/dockerized/${name}" \
			${extraopts} \
			"${docker_image}" \
			$cmd \
	| logger -i -t "systemd-docker-runner ${docker_container_name}" -p daemon.info

	exec "${docker_bin}" run --name="${name}" $opts \
			 $(_docker_opts -e env) \
			 $(_docker_opts -p ports) \
			 $(_docker_opts -v volumes) \
 			 --cidfile="/run/dockerized/${name}" \
			 ${extraopts} \
			 "${docker_image}" \
			 $cmd
}


_docker_stop() {
	local cid=$(_cid $1)
	"${docker_bin}" stop ${cid} && "${docker_bin}" rm ${cid} && rm "/run/dockerized/${1}"
}


case "$1" in 
	start)
		_docker_start "$2" "-d" $3
		;;
	stop)
		_docker_stop "$2"		
		;;
	*)
		echo $"Usage: $0 {start|stop}"
		RETVAL=2
		;;
esac

exit $RETVAL

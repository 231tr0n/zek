#!/usr/bin/env bash
#
# zek - Kubernetes node container.
#
# Roles:
#   master   control-plane node: kubeadm init (first node) or kubeadm join
#            --control-plane (additional nodes, MASTER_JOIN=1) + kubelet
#            supervisor
#   worker   kubeadm join + kubelet supervisor
#   kubectl  kubectl client against the published cluster config
#   lb       haproxy in front of the control-plane nodes (only started by
#            the manager for multi-master clusters)
#
# Flags: every input env var can also be passed as a flag after the role
# (the name in lower case with '_' as '-', e.g. POD_CIDR -> --pod-cidr); the
# flag wins when both are set (value flags take --flag value or
# --flag=value; --master-join and --no-host-modules are bare booleans, also
# accepted as --flag=1). Unknown arguments die on the node roles - only the
# kubectl role forwards them. `--` ends flag parsing; it and everything
# after it is left for the role - kubectl arguments pass through (kubectl
# needs the `--` itself, e.g. for `exec POD -- CMD`):
#   --cluster-dir PATH        (CLUSTER_DIR, default /etc/cluster)
#   --node-name NAME          (NODE_NAME, default the container hostname)
#   --pod-cidr CIDR           (POD_CIDR, default 10.244.0.0/16)
#   --node-dns IP             (NODE_DNS; normally docker --dns owns this)
#   --api-endpoint ADDR       (API_ENDPOINT, default <master-ip>:6443)
#   --master-join             (MASTER_JOIN=1: join as a control plane)
#   --join-token TOKEN        (JOIN_TOKEN)
#   --join-ca-hash HASH       (JOIN_CA_HASH)
#   --join-api-endpoint ADDR  (JOIN_API_ENDPOINT)
#   --join-cert-key KEY       (JOIN_CERT_KEY)
#   --lb-backends "IP ..."    (LB_BACKENDS, space separated)
#   --kubeconfig PATH         (KUBECONFIG; kubectl defaults to the published
#                              admin.conf)
#   --no-host-modules         (NO_HOST_MODULES=1: skip host module setup)
#   WAIT_TIMEOUT (env only, no flag: zek.sh passes --timeout through) bounds
#   the kubectl role's wait for the published config; default 600s.
#
# Persistence and host isolation:
#   - Everything lives on the container's own writable layer: node state
#     (kubelet, containerd, etcd) under /var/lib, /etc/kubernetes symlinked
#     onto it, and the published cluster credentials (admin.conf, join
#     token, CA hash, API endpoint, certificate key) under /etc/cluster.
#     That survives docker stop/start, docker restart and host reboots,
#     and dies with the container on docker rm.
#   - The manager reads the credentials from the first master's
#     /etc/cluster and passes them to joining nodes as the JOIN_* env
#     vars; there is no shared volume between nodes.
#   - Host effects are limited to in-memory kernel setup (loading modules the
#     host lacks, enabling a few sysctls, and raising the host-wide inotify
#     quota); sysctls and any modules we loaded are undone on shutdown, the
#     inotify quota stays raised on purpose (other zek containers need it),
#     and nothing touches disk. Set NO_HOST_MODULES=1 to skip all host setup.
set -euo pipefail

# Reassigned by the flags after parsing, so not readonly (the full flag/env
# list is in the header).
CLUSTER_DIR="${CLUSTER_DIR:-/etc/cluster}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
readonly KUBELET_CONFIG=/var/lib/kubelet/config.yaml
readonly KUBEADM_FLAGS=/var/lib/kubelet/kubeadm-flags.env
# Passthrough kubectl args (plus `--` itself) collected by parse_role_flags;
# node roles must leave this empty (they die on stray args instead).
ROLE_ARGS=()

CONTAINERD_PID=""
SUPERVISOR_PID=""
declare -A SYSCTL_BEFORE=()
# Modules the host already had before preflight_host ran (space separated):
# cleanup only unloads the ones NOT in this list. Set at the end of
# preflight_host, so cleanup can tell "we never set the host up" (an early
# die) from "we loaded something" - an empty list must never trigger rmmod.
HOST_SETUP_DONE=0
HOST_MODULES_PREEXISTING=""

log() { echo "[zek] $*" >&2; }
warn() { echo "[zek] WARNING: $*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

# Run a command with its output captured to a log file; on failure surface
# the log on stderr and die. kubeadm's preflight/cert chatter is one-shot
# and verbose, so it stays out of docker logs unless it fails.
run_logged() { # logfile desc cmd...
	local logfile=$1 desc=$2
	shift 2
	if ! "$@" > "${logfile}" 2>&1; then
		cat "${logfile}" >&2
		die "${desc}"
	fi
}

cleanup() {
	# Clear the traps first: a TERM arriving mid-cleanup must not re-enter
	# this function, and the shell keeps the status that triggered the EXIT
	# trap (die's non-zero, or 0 from `exit 0` in the TERM handler), so a
	# failed kubeadm run still exits non-zero.
	trap - EXIT TERM INT
	# Undo the host-level kernel setup: restore sysctls and unload any modules
	# we loaded (only ones the host did not already have; with
	# NO_HOST_MODULES=1 nothing was loaded, so the unload is skipped too -
	# otherwise an idle host module could be pulled out from under the host).
	# Unloading may fail while other processes still use them, which is fine.
	log "shutting down"
	local sysctl_key kernel_module
	[[ -n ${CONTAINERD_PID} ]] && kill "${CONTAINERD_PID}" 2> /dev/null || true
	[[ -n ${SUPERVISOR_PID} ]] && kill "${SUPERVISOR_PID}" 2> /dev/null || true
	for sysctl_key in "${!SYSCTL_BEFORE[@]}"; do
		[[ -n ${SYSCTL_BEFORE[${sysctl_key}]} ]] && sysctl -w "${sysctl_key}=${SYSCTL_BEFORE[${sysctl_key}]}" > /dev/null 2>&1 || true
	done
	# Only touch host modules when preflight_host actually ran: die() can
	# fire before that (flag parsing, kubeadm failures on a first start),
	# and an empty "loaded by us" list would otherwise rmmod modules the
	# host itself was using.
	if [[ ${HOST_SETUP_DONE:-0} -eq 1 ]]; then
		for kernel_module in br_netfilter vxlan; do
			case " ${HOST_MODULES_PREEXISTING} " in
				*" ${kernel_module} "*) ;;
				*) rmmod "${kernel_module}" 2> /dev/null || true ;;
			esac
		done
	fi
}
# Run cleanup exactly once on every exit path: docker stop sends TERM
# (converted to exit 0 so the stop is not reported as a failure), and
# die()/kubeadm failures reach it through the EXIT trap with their status
# intact.
trap 'exit 0' TERM INT
trap cleanup EXIT

preflight_host() {
	# In-memory kernel setup only: it does not survive a reboot and touches no
	# disk. Skip entirely with NO_HOST_MODULES=1 if the host manages its own
	# modules (e.g. they were already loaded at boot).
	[[ ${NO_HOST_MODULES:-0} -eq 1 ]] && return 0
	for module in br_netfilter vxlan; do
		if [[ -d "/sys/module/${module}" ]]; then
			HOST_MODULES_PREEXISTING="${HOST_MODULES_PREEXISTING} ${module}"
		else
			modprobe "${module}" 2> /dev/null || true
		fi
	done
	for sysctl_key in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables; do
		SYSCTL_BEFORE[${sysctl_key}]="$(sysctl -n "${sysctl_key}" 2> /dev/null || true)"
		sysctl -w "${sysctl_key}=1" > /dev/null 2>&1 || true
	done
	# Every node container runs as uid 0 in the init namespace, so they all
	# share the host's per-uid inotify instance quota (default 128). A
	# 4-node cluster already exhausts it and kubelet then dies with
	# "inotify_init: too many open files" in cAdvisor, so raise the quota
	# for the whole host (best effort, kept on purpose after exit: the
	# other zek containers still need it).
	if [[ -w /proc/sys/fs/inotify/max_user_instances ]]; then
		local inotify_limit
		inotify_limit="$(cat /proc/sys/fs/inotify/max_user_instances 2> /dev/null || echo 0)"
		{ [[ ${inotify_limit} -ge 1024 ]] || sysctl -w fs.inotify.max_user_instances=1024 > /dev/null; } 2> /dev/null || true
	fi
	# Marked only on the fall-through path: with NO_HOST_MODULES=1 the
	# early return above leaves it unset, and cleanup then keeps its hands
	# off the host's modules.
	HOST_SETUP_DONE=1
}

ensure_resolv_conf() {
	# kubelet copies the node resolv.conf into pod sandboxes where 127.0.0.11
	# (Docker's embedded DNS) would be a per-sandbox loopback and fail. Extract
	# the real upstream IPs, skipping loopback/link-local stubs (e.g. a host
	# systemd-resolved 127.0.0.53 is not routable from our netns), and fall
	# back to public resolvers when nothing usable remains.
	local upstream_ips upstream_ip
	# NODE_DNS is an optional override for manual `docker run -e
	# NODE_DNS="..."` usage; normally the docker --dns resolv.conf parsed
	# below provides the upstreams. awk reads the nameserver field only:
	# a flat grep would also pick up IPs from comments and options.
	upstream_ips="${NODE_DNS:-}"
	if [[ -z ${upstream_ips} ]]; then
		upstream_ips="$(awk '$1 == "nameserver" && $2 !~ /^127\.|^169\.254\./ { print $2 }' /etc/resolv.conf \
			| sort -u | tr '\n' ' ')" || true
	fi
	[[ -n ${upstream_ips} ]] || upstream_ips="1.1.1.1 8.8.8.8"
	{
		echo "search ."
		for upstream_ip in ${upstream_ips}; do echo "nameserver ${upstream_ip}"; done
	} > /etc/resolv.conf
}

ensure_etc_kubernetes() {
	# kubeadm insists on /etc/kubernetes; keep its state under
	# /var/lib/kubernetes on the container's writable layer so it survives
	# stop/start and restarts (and dies with the container on docker rm,
	# like the rest of the node state).
	mkdir -p /var/lib/kubernetes
	ln -sfn /var/lib/kubernetes /etc/kubernetes
}

start_containerd() {
	[[ -f /etc/containerd/config.toml ]] || containerd config default > /etc/containerd/config.toml
	# Search both the Alpine-provided and user-installed CNI binaries.
	# Anchored to the key so a reordered config cannot mis-substitute.
	sed -i "s|^\([[:space:]]*bin_dirs = \)\[.*\]|\1['/opt/cni/bin', '/usr/libexec/cni']|" /etc/containerd/config.toml
	# /var/lib lives on the container's overlay rootfs (no volume), and overlay
	# cannot be nested on overlay, so use the native snapshotter instead.
	sed -i "s|^\([[:space:]]*snapshotter = \).*|\1'native'|" /etc/containerd/config.toml
	# In containerd >=2.3 the transfer service only accepts unpack requests
	# whose snapshotter is listed in its unpack_config; the generated config
	# only knows the default (overlayfs) one. Without this, every CRI pull -
	# kubeadm, crictl, kubelet - fails with "no unpack platforms defined".
	if ! grep -q "unpack_config" /etc/containerd/config.toml; then
		local host_arch
		case "$(uname -m)" in
			x86_64) host_arch="amd64" ;;
			aarch64) host_arch="arm64" ;;
			armv7l) host_arch="arm" ;;
			*) host_arch="amd64" ;;
		esac
		sed -i "/\[plugins.'io.containerd.transfer.v1.local'\]/a\\
  unpack_config = [{ platform = \"linux/${host_arch}\", snapshotter = \"native\" }]" /etc/containerd/config.toml
	fi
	containerd > /var/log/containerd.log 2>&1 &
	CONTAINERD_PID=$!
	# 60s is plenty for containerd to create its socket; a longer budget
	# would only hide a broken install, and the log has the reason.
	for _ in $(seq 1 60); do
		[[ -S /run/containerd/containerd.sock ]] && return 0
		sleep 1
	done
	die "containerd did not start (see /var/log/containerd.log)"
}

cleanup_stale_cri() {
	# Purge dead pods/sandboxes left by a previous node instance so kubelet
	# recreates them fresh; images are kept.
	log "purging stale containers from previous node instance"
	crictl rmp -f -a > /dev/null 2>&1 || true
	crictl rm -f -a > /dev/null 2>&1 || true
}

import_k8s_images() {
	# The image build preloaded the kubeadm images (apiserver, etcd, scheduler,
	# controller-manager, coredns, kube-proxy, pause) as tarballs under
	# /opt/zek/images. Import them into the CRI image store (content only,
	# --no-unpack: no mounts needed, unpacking happens lazily when the kubelet
	# first pulls them). Only runs on a fresh node, once.
	if ! command -v ctr > /dev/null 2>&1; then
		warn "ctr not installed; skipping kubeadm image preload"
		return 0
	fi
	log "importing preloaded kubeadm images"
	local tarball
	for tarball in /opt/zek/images/*.tar; do
		[[ -e ${tarball} ]] || continue
		ctr --namespace k8s.io images import --no-unpack "${tarball}" > /dev/null 2>&1 \
			|| warn "failed to import ${tarball}"
	done
}

# First global IPv4: the node's own address on the cluster network. awk
# reads the whole input (no early exit) so `ip` never dies of SIGPIPE -
# under pipefail that would kill the caller with no message.
node_ip() {
	ip -4 -o addr show scope global | awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }'
}

# sha256 of the CA public key - the exact format kubeadm expects for the
# caCertHashes join-discovery field ("sha256:<hash>"). awk takes the last
# field instead of stripping on "=" with sed: openssl prints
# "SHA2-256(stdin)= <hash>".
get_ca_hash() {
	openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt \
		| openssl pkey -pubin -outform der 2> /dev/null \
		| openssl dgst -sha256 -hex | awk '{ print $NF }'
}

patch_kube_proxy() {
	# In a container netns kube-proxy cannot grow the global conntrack table
	# (EACCES); disable its auto-tuning via the ConfigMap.
	log "disabling kube-proxy conntrack tuning"
	local proxy_dir=/etc/zek/kube-proxy
	mkdir -p "${proxy_dir}"
	[[ -n ${KUBECONFIG:-} ]] || export KUBECONFIG=/etc/kubernetes/admin.conf
	kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' > "${proxy_dir}/config.conf"
	kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.kubeconfig\.conf}' > "${proxy_dir}/kubeconfig.conf"
	[[ -s "${proxy_dir}/config.conf" ]] || return 0
	sed -i -e 's/^\(  maxPerCore: \)null/\10/' -e 's/^\(  min: \)null/\10/' "${proxy_dir}/config.conf"
	kubectl -n kube-system create configmap kube-proxy \
		--from-file=config.conf="${proxy_dir}/config.conf" \
		--from-file=kubeconfig.conf="${proxy_dir}/kubeconfig.conf" \
		--dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1 || true
	kubectl -n kube-system rollout restart daemonset kube-proxy > /dev/null 2>&1 || true
}

# failSwapOn belongs in the kubelet config file: the --fail-swap-on CLI flag
# is deprecated and will eventually disappear. kubeadm owns config.yaml, so
# enforce the key here right before every kubelet start - that covers init,
# resume and all join paths regardless of what kubeadm's defaults write.
ensure_kubelet_config() {
	[[ -f ${KUBELET_CONFIG} ]] || return 0
	sed -i 's/^failSwapOn:[[:space:]]*.*/failSwapOn: false/' "${KUBELET_CONFIG}"
	grep -q '^failSwapOn:[[:space:]]*false[[:space:]]*$' "${KUBELET_CONFIG}" && return 0
	printf '\nfailSwapOn: false\n' >> "${KUBELET_CONFIG}"
}

# Keep kubelet alive and restart it when it exits. kubeadm writes its config
# and flags file, and without systemd we feed the kubeconfig args ourselves.
# config.yaml appearing marks kubeadm init/join as done; init does not put
# kubelet.conf on kubelet's default path, so it must always be passed on.
kubelet_supervisor() {
	trap 'exit 0' TERM INT
	while :; do
		if [[ -f ${KUBELET_CONFIG} ]]; then
			ensure_kubelet_config
			local -a kubelet_args=()
			if [[ -f ${KUBEADM_FLAGS} ]]; then
				# kubeadm generates this file at runtime, so shellcheck
				# cannot read it here.
				# shellcheck source=/dev/null
				source "${KUBEADM_FLAGS}"
				# Drop any deprecated CLI copy kubeadm may still ship
				# in KUBELET_KUBEADM_ARGS; the config file carries
				# the setting now. Intentional word-splitting: the file
				# holds a flat space-separated flag string, not an array.
				local kubeadm_flag
				for kubeadm_flag in ${KUBELET_KUBEADM_ARGS:-}; do
					case "${kubeadm_flag}" in
						--fail-swap-on | --fail-swap-on=*) ;;
						*) kubelet_args+=("${kubeadm_flag}") ;;
					esac
				done
			fi
			if [[ -f /etc/kubernetes/bootstrap-kubelet.conf ]]; then
				kubelet_args+=(--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf)
			elif [[ -f /etc/kubernetes/kubelet.conf ]]; then
				kubelet_args+=(--kubeconfig=/etc/kubernetes/kubelet.conf)
			fi
			# Full kubelet log goes to /var/log/kubelet.log; docker logs
			# only gets warnings/errors/fatals and non-klog lines
			# (panics). At --v=2 klog's I-lines are per-pod sync spam
			# that used to flood `docker logs` of every node, and klog
			# renders big values (kubelet config, /proc/swaps) as a
			# multi-line `...=<` block with a tab-indented body and a
			# lone `>` closer that carry no I-prefix - awk drops those
			# with the header. fflush() keeps the sparse output
			# in real time through the pipe; wait returns the awk pid, so
			# if awk ever died while kubelet was still alive, the pkill
			# keeps the start below from ever running two kubelets.
			# Kill by command line, not comm: gcompat runs the glibc
			# kubelet through musl's loader, so comm is ld-musl-x86_64,
			# and a comm match never finds it.
			pkill -f "/usr/local/bin/kubelet" > /dev/null 2>&1 || true
			# cgroupfs matches containerd's default (SystemdCgroup=false);
			# switching this to systemd also requires flipping containerd's
			# config, or every container fails to start. Last on the line so
			# it beats kubeadm's generated config.yaml (flags > config file).
			kubelet --config "${KUBELET_CONFIG}" --hostname-override "${NODE_NAME}" \
				--v=2 "${kubelet_args[@]}" --cgroup-driver=cgroupfs 2>&1 \
				| tee -a /var/log/kubelet.log \
				| awk '
					inval {
						if (substr($0, 1, 1) == "\t" ||
							$0 ~ /^[[:space:]]*>[[:space:]]*$/) next
						inval = 0
					}
					/<$/ { inval = 1 }
					/^I[0-9]{4} / { next }
					{ print; fflush() }
				' &
			local filter_pid=$!
			log "kubelet running (full log: /var/log/kubelet.log)"
			wait "${filter_pid}" 2> /dev/null || true
			log "kubelet exited, restarting"
		fi
		sleep 2
	done
}

ensure_cni_dirs() {
	# Nodes start with no CNI; the user installs one whose installer runs as a
	# non-root pod user (e.g. calico uses uid 10001) and drops binaries/config
	# onto the node. Pre-create both paths world-writable so it works:
	# /usr/libexec/cni is where Alpine's packages put plugins, /opt/cni/bin
	# is where the CNI providers' installers drop theirs (containerd's
	# bin_dirs above searches both).
	local cni_dir
	for cni_dir in /etc/cni/net.d /opt/cni/bin; do mkdir -p "${cni_dir}" && chmod 0777 "${cni_dir}"; done
}

ensure_shared_mounts() {
	# Calico's eBPF bootstrap and cilium mount host fs types (bpffs) into pods
	# with mount propagation; kubelet rejects that unless the parent mounts are
	# shared. Applies to this container's mount namespace only.
	mount --make-rshared / 2> /dev/null || true
	mount --make-rshared /sys 2> /dev/null || true
	mount --make-rshared /run 2> /dev/null || true
}

ensure_bpffs() {
	# Pre-mount the BPF filesystem so eBPF CNIs (cilium, calico eBPF) start
	# cleanly instead of racing to mount it in-band on every start. A no-op
	# when a CNI already mounted it or the host lacks BPF support.
	grep -q " /sys/fs/bpf " /proc/mounts 2> /dev/null && return 0
	mkdir -p /sys/fs/bpf
	mount -t bpf bpf /sys/fs/bpf 2> /dev/null \
		|| warn "bpffs not mounted at /sys/fs/bpf (BPF-based CNIs may need it)"
}

node_setup() {
	preflight_host
	ensure_resolv_conf
	ensure_etc_kubernetes
	ensure_cni_dirs
	ensure_shared_mounts
	ensure_bpffs
	start_containerd
	cleanup_stale_cri
	kubelet_supervisor &
	SUPERVISOR_PID=$!
}

# Publish the credentials zek.sh reads (via docker exec) to hand to joining
# nodes. Everything is extracted first and written only once all of it is
# known, so a failure cannot leave a half-published set behind; admin.conf
# goes last and marks the set as complete (the resume path republishes when
# it is missing). The token and upload-certs both need a serving API, so
# they are retried briefly.
publish_cluster_credentials() {
	local join_token="" join_cert_key="" join_ca_hash="" upload_ok=""
	API_ENDPOINT="${API_ENDPOINT:-$(node_ip):6443}"
	mkdir -p "${CLUSTER_DIR}"
	[[ -n ${KUBECONFIG:-} ]] || export KUBECONFIG=/etc/kubernetes/admin.conf
	# Explicit check: the resume path calls this from the right of || where
	# errexit is off, and a failed hash would only surface later as a
	# confusing "could not extract the join credentials".
	# shellcheck disable=SC2310  # failure is handled by the || die
	join_ca_hash="$(get_ca_hash)" || die "cannot hash the cluster CA (/etc/kubernetes/pki/ca.crt missing?)"
	# Generate the certificate key ourselves and pass it to upload-certs
	# instead of scraping it from kubeadm's human-readable output - that
	# wording changed between releases before (v1.37 moved it to its own
	# line) and would break extraction again. The key is a hex-encoded
	# 32-byte AES key, so 64 hex characters.
	join_cert_key="$(openssl rand -hex 32)"
	for _ in $(seq 1 60); do
		# No tr needed: command substitution already strips the
		# trailing newline kubeadm prints.
		join_token="$(kubeadm token create --ttl 0 2> /dev/null)" || join_token=""
		upload_ok=""
		kubeadm init phase upload-certs --upload-certs \
			--certificate-key "${join_cert_key}" > /dev/null 2>&1 && upload_ok=1
		[[ -n ${join_token} ]] && [[ -n ${upload_ok} ]] && break
		sleep 2
	done
	[[ -n ${join_token} ]] && [[ -n ${upload_ok} ]] && [[ -n ${join_ca_hash} ]] \
		|| die "could not extract the join credentials (token/certificate key/CA hash)"
	printf '%s' "${join_token}" > "${CLUSTER_DIR}/token"
	printf '%s' "${join_cert_key}" > "${CLUSTER_DIR}/cert-key"
	echo "${API_ENDPOINT}" > "${CLUSTER_DIR}/api-endpoint"
	printf '%s' "${join_ca_hash}" > "${CLUSTER_DIR}/ca-hash"
	cp /etc/kubernetes/admin.conf "${CLUSTER_DIR}/admin.conf"
	log "published join credentials to ${CLUSTER_DIR} (endpoint: ${API_ENDPOINT})"
}

# First control-plane node: kubeadm init against the API endpoint, then
# publish the credentials the manager hands to every joining node. The
# endpoint every kubeconfig points at: the load balancer's IP for
# multi-master clusters, the first master's own address otherwise; zek.sh
# passes it as API_ENDPOINT, the :- default covers runs without it.
init_control_plane() {
	local advertise_ip k8s_version
	advertise_ip="$(node_ip)"
	API_ENDPOINT="${API_ENDPOINT:-${advertise_ip}:6443}"
	log "initializing control plane on ${NODE_NAME} (${advertise_ip})"
	mkdir -p "${CLUSTER_DIR}"
	import_k8s_images
	# Pin the version the binaries report: kubeadm's compiled default can
	# skew ahead of them (v1.37.0 binaries defaulting to v1.37.1 images),
	# which would dodge the preloaded store and force a live registry pull
	# on every init - minutes lost on a slow day, fatal under parallel e2e
	# load. The Dockerfile preloads exactly the binary version, so pinning
	# here keeps init on the preloaded images.
	k8s_version="$(kubeadm version -o short)"
	# kubeadm runs on CLI flags only, no --config document: its decoder
	# sniffs each document and parses flow-style YAML as strict JSON,
	# which fails. kubeadm's own defaults fill everything else (its
	# KubeletConfiguration generation replaces the cgroupDriver input).
	run_logged /var/log/kubeadm-init.log "kubeadm init failed" \
		kubeadm init \
		--kubernetes-version="${k8s_version}" \
		--apiserver-advertise-address="${advertise_ip}" \
		--apiserver-bind-port=6443 \
		--control-plane-endpoint="${API_ENDPOINT}" \
		--node-name="${NODE_NAME}" \
		--cri-socket=unix:///run/containerd/containerd.sock \
		--pod-network-cidr="${POD_CIDR}" \
		--ignore-preflight-errors=all
	# Every phase ran, including the bootstrap-token RBAC that lets joining
	# nodes fetch cluster-info; run_master uses this to tell a completed
	# init from one that died in wait-control-plane.
	touch "${CLUSTER_DIR}/init-complete"

	export KUBECONFIG=/etc/kubernetes/admin.conf
	patch_kube_proxy

	publish_cluster_credentials
	log "control plane ready (endpoint: ${API_ENDPOINT})"
	log "no CNI installed; nodes are NotReady until you install one (flannel, cilium, ...)"
}

# Additional control-plane node (the manager sets MASTER_JOIN=1): joins
# through the API endpoint with the certificate key published by the first
# master, becoming a member of the stacked etcd cluster.
join_control_plane() {
	[[ -n ${JOIN_TOKEN:-} ]] && [[ -n ${JOIN_CA_HASH:-} ]] && [[ -n ${JOIN_API_ENDPOINT:-} ]] \
		&& [[ -n ${JOIN_CERT_KEY:-} ]] \
		|| die "control-plane join needs JOIN_TOKEN, JOIN_CA_HASH, JOIN_API_ENDPOINT and JOIN_CERT_KEY (check --join-token/--join-ca-hash/--join-api-endpoint/--join-cert-key)"
	local join_token="${JOIN_TOKEN}" join_ca_hash="${JOIN_CA_HASH}" join_api_endpoint="${JOIN_API_ENDPOINT}"
	log "joining ${NODE_NAME} as a control-plane node via ${join_api_endpoint}"
	import_k8s_images
	run_logged /var/log/kubeadm-join.log "control-plane join failed" \
		kubeadm join "${join_api_endpoint}" \
		--token "${join_token}" \
		--discovery-token-ca-cert-hash "sha256:${join_ca_hash}" \
		--certificate-key "${JOIN_CERT_KEY}" \
		--control-plane \
		--node-name "${NODE_NAME}" \
		--cri-socket=unix:///run/containerd/containerd.sock \
		--ignore-preflight-errors=all
	mkdir -p "${CLUSTER_DIR}"
	touch "${CLUSTER_DIR}/init-complete"
}

run_master() {
	node_setup

	# Recovery for a creation interrupted before kubeadm finished (crash,
	# power loss, host reboot during `up`): the partial certs/state cannot
	# be resumed by kubeadm, so wipe it and start over. Two interruption
	# points need handling:
	# - certs written but no kubelet.conf yet (interrupted very early);
	# - kubelet.conf present but the kubeadm run never finished. kubelet.conf
	#   is written in the kubeconfig phase, long before wait-control-plane,
	#   the bootstrap-token RBAC that lets nodes fetch cluster-info, and
	#   the addons - so an init that dies in wait-control-plane (4m budget,
	#   kubeadm's default; re-check `kubeadm init --help` on a k8s bump -
	#   parallel clusters can exceed it) would otherwise resume
	#   as a half-initialized cluster whose joins all 403 on
	#   cluster-info. The same holds for an interrupted control-plane
	#   join: its kubelet.conf also appears before the etcd member add
	#   and static-pod write finish. Without completion evidence (the
	#   init-complete marker, which both init and join write last, or
	#   published credentials, which only exist after a completed init)
	#   wipe and start over - the interrupted run is then redone below.
	if [[ ! -f /etc/kubernetes/kubelet.conf ]] && [[ -f /etc/kubernetes/pki/ca.crt ]]; then
		log "interrupted control-plane setup detected; resetting partial state"
		kubeadm reset --force --ignore-preflight-errors=all > /dev/null 2>&1 || true
	elif [[ -f /etc/kubernetes/kubelet.conf ]] \
		&& [[ ! -f "${CLUSTER_DIR}/init-complete" ]] \
		&& [[ ! -f "${CLUSTER_DIR}/admin.conf" ]] \
		&& [[ ! -f "${CLUSTER_DIR}/token" ]]; then
		log "interrupted control-plane init/join detected; resetting partial state"
		kubeadm reset --force --ignore-preflight-errors=all > /dev/null 2>&1 || true
	fi

	# kubelet.conf exists after either kubeadm init or a control-plane join,
	# so it marks this node as already configured: only the supervisor needs
	# to come back up.
	if [[ -f /etc/kubernetes/kubelet.conf ]]; then
		log "control plane already set up, resuming"
		# Complete a publish that was interrupted by a crash/restart -
		# admin.conf is written last and marks the set as complete.
		# Only the first master publishes: a joining master never has
		# admin.conf on its own layer, and republishing would rotate the
		# bootstrap token and certificate key the stored credentials
		# still point at (kubeadm's upload-certs secret), breaking the
		# next control-plane join.
		if [[ ${MASTER_JOIN:-0} -ne 1 && ! -f "${CLUSTER_DIR}/admin.conf" ]]; then
			log "published credentials incomplete; republishing"
			publish_cluster_credentials
		fi
	elif [[ ${MASTER_JOIN:-0} -eq 1 ]]; then
		join_control_plane
	else
		init_control_plane
	fi

	wait "${SUPERVISOR_PID}"
}

run_worker() {
	node_setup

	if [[ -f /etc/kubernetes/kubelet.conf ]]; then
		log "node already joined, resuming"
	else
		# A join interrupted before it finished (crash/power loss) leaves
		# the downloaded cluster certs behind; wipe them so kubeadm join
		# starts clean. kubelet.conf marks a complete join.
		if [[ -f /etc/kubernetes/pki/ca.crt ]]; then
			log "interrupted join detected; resetting partial state"
			kubeadm reset --force --ignore-preflight-errors=all > /dev/null 2>&1 || true
		fi
		[[ -n ${JOIN_TOKEN:-} ]] && [[ -n ${JOIN_CA_HASH:-} ]] && [[ -n ${JOIN_API_ENDPOINT:-} ]] \
			|| die "worker join needs JOIN_TOKEN, JOIN_CA_HASH and JOIN_API_ENDPOINT (check --join-token/--join-ca-hash/--join-api-endpoint)"
		local join_token="${JOIN_TOKEN}" join_ca_hash="${JOIN_CA_HASH}" join_api_endpoint="${JOIN_API_ENDPOINT}"
		log "joining ${NODE_NAME} to ${join_api_endpoint}"
		import_k8s_images
		run_logged /var/log/kubeadm-join.log "kubeadm join failed" \
			kubeadm join "${join_api_endpoint}" \
			--token "${join_token}" \
			--discovery-token-ca-cert-hash "sha256:${join_ca_hash}" \
			--node-name "${NODE_NAME}" \
			--cri-socket=unix:///run/containerd/containerd.sock \
			--ignore-preflight-errors=all
	fi

	wait "${SUPERVISOR_PID}"
}

# TCP load balancer in front of the control-plane nodes (multi-master
# clusters only). The manager passes the node addresses as LB_BACKENDS
# (space-separated IPs); haproxy health-checks them so a dead master is
# taken out of rotation. The stats page on :8404 shows backend state.
run_lb() {
	[[ -n ${LB_BACKENDS:-} ]] || die "LB_BACKENDS must list the control-plane IPs (check --lb-backends)"
	local haproxy_cfg=/etc/haproxy/haproxy.cfg backend_index=1 backend_ip
	mkdir -p /etc/haproxy
	{
		# HAPROXY instead of EOF marks this as config: lint.sh checks
		# every EOF heredoc as canonical yamlfmt kyaml output, and runs
		# `haproxy -c` plus a tab/whitespace style check on the HAPROXY
		# ones (assembled with a synthetic backend server).
		cat << 'HAPROXY'
global
	maxconn 4096

defaults
	mode tcp
	timeout connect 5s
	# kubectl exec/attach/port-forward streams are long-lived: a 7-day
	# idle timeout instead of 0 keeps haproxy from warning on startup.
	timeout client 604800s
	timeout server 604800s

frontend k8s-api
	bind *:6443
	default_backend apiservers

backend apiservers
	balance roundrobin
	option tcp-check
HAPROXY
		for backend_ip in ${LB_BACKENDS}; do
			printf '\tserver cp%d %s:6443 check inter 2s fall 3 rise 2\n' "${backend_index}" "${backend_ip}"
			backend_index=$((backend_index + 1))
		done
		cat << 'HAPROXY'

frontend stats
	mode http
	timeout client 30s
	bind *:8404
	stats enable
	stats uri /
HAPROXY
	} > "${haproxy_cfg}"
	log "load balancer for: ${LB_BACKENDS}"
	exec haproxy -f "${haproxy_cfg}"
}

run_kubectl() {
	# KUBECONFIG (env or --kubeconfig) selects an explicit kubeconfig;
	# otherwise fall back to the cluster's published admin.conf, which every
	# `zek kubectl` call and every 2s poll during cluster bring-up waits for
	# - so only log when there is something to wait for: the common case is
	# "config already there".
	if [[ -z ${KUBECONFIG:-} ]]; then
		if [[ ! -f "${CLUSTER_DIR}/admin.conf" ]]; then
			log "waiting for the published cluster config (${CLUSTER_DIR}/admin.conf)"
			# Bounded by WAIT_TIMEOUT (zek.sh passes --timeout through,
			# default 600s) so a dead master fails this call instead of
			# hanging every `zek kubectl` poll for ten minutes.
			local deadline=$((SECONDS + ${WAIT_TIMEOUT:-600}))
			while [[ ${SECONDS} -lt ${deadline} ]]; do
				[[ -f "${CLUSTER_DIR}/admin.conf" ]] && break
				sleep 2
			done
		fi
		[[ -f "${CLUSTER_DIR}/admin.conf" ]] || die "no admin.conf found; is the master running?"
		KUBECONFIG="${CLUSTER_DIR}/admin.conf"
	fi
	export KUBECONFIG
	[[ $# -eq 0 ]] && exec bash
	exec kubectl "$@"
}

# Consume the configuration flags for the current role; every input env var
# has a flag twin of the same name (see the header). What is left -
# everything unrecognized, plus `--` and everything after it - stays in
# ROLE_ARGS: for the kubectl role that is how kubectl arguments (and the
# `--` delimiter itself, which kubectl needs for exec/attach) pass through;
# the node roles die on stray arguments instead of ignoring them.
parse_role_flags() {
	ROLE_ARGS=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--)
				# forward the delimiter: `kubectl exec POD -- CMD` needs it
				shift
				ROLE_ARGS+=("--" "$@")
				break
				;;
			--cluster-dir)
				[[ $# -ge 2 ]] || die "--cluster-dir needs a value (check --cluster-dir/CLUSTER_DIR)"
				CLUSTER_DIR="$2"
				shift 2
				;;
			--cluster-dir=*) CLUSTER_DIR="${1#*=}" && shift ;;
			--node-name)
				[[ $# -ge 2 ]] || die "--node-name needs a value (check --node-name/NODE_NAME)"
				NODE_NAME="$2"
				shift 2
				;;
			--node-name=*) NODE_NAME="${1#*=}" && shift ;;
			--pod-cidr)
				[[ $# -ge 2 ]] || die "--pod-cidr needs a value (check --pod-cidr/POD_CIDR)"
				POD_CIDR="$2"
				shift 2
				;;
			--pod-cidr=*) POD_CIDR="${1#*=}" && shift ;;
			--node-dns)
				[[ $# -ge 2 ]] || die "--node-dns needs a value (check --node-dns/NODE_DNS)"
				NODE_DNS="$2"
				shift 2
				;;
			--node-dns=*) NODE_DNS="${1#*=}" && shift ;;
			--api-endpoint)
				[[ $# -ge 2 ]] || die "--api-endpoint needs a value (check --api-endpoint/API_ENDPOINT)"
				API_ENDPOINT="$2"
				shift 2
				;;
			--api-endpoint=*) API_ENDPOINT="${1#*=}" && shift ;;
			--master-join | --master-join=1)
				MASTER_JOIN=1
				shift
				;;
			--master-join=*) die "--master-join is a boolean; use --master-join (or --master-join=1)" ;;
			--join-token)
				[[ $# -ge 2 ]] || die "--join-token needs a value (check --join-token/JOIN_TOKEN)"
				JOIN_TOKEN="$2"
				shift 2
				;;
			--join-token=*) JOIN_TOKEN="${1#*=}" && shift ;;
			--join-ca-hash)
				[[ $# -ge 2 ]] || die "--join-ca-hash needs a value (check --join-ca-hash/JOIN_CA_HASH)"
				JOIN_CA_HASH="$2"
				shift 2
				;;
			--join-ca-hash=*) JOIN_CA_HASH="${1#*=}" && shift ;;
			--join-api-endpoint)
				[[ $# -ge 2 ]] || die "--join-api-endpoint needs a value (check --join-api-endpoint/JOIN_API_ENDPOINT)"
				JOIN_API_ENDPOINT="$2"
				shift 2
				;;
			--join-api-endpoint=*) JOIN_API_ENDPOINT="${1#*=}" && shift ;;
			--join-cert-key)
				[[ $# -ge 2 ]] || die "--join-cert-key needs a value (check --join-cert-key/JOIN_CERT_KEY)"
				JOIN_CERT_KEY="$2"
				shift 2
				;;
			--join-cert-key=*) JOIN_CERT_KEY="${1#*=}" && shift ;;
			--lb-backends)
				[[ $# -ge 2 ]] || die "--lb-backends needs a value (check --lb-backends/LB_BACKENDS)"
				LB_BACKENDS="$2"
				shift 2
				;;
			--lb-backends=*) LB_BACKENDS="${1#*=}" && shift ;;
			--kubeconfig)
				[[ $# -ge 2 ]] || die "--kubeconfig needs a value (check --kubeconfig/KUBECONFIG)"
				KUBECONFIG="$2"
				shift 2
				;;
			--kubeconfig=*) KUBECONFIG="${1#*=}" && shift ;;
			--no-host-modules | --no-host-modules=1)
				NO_HOST_MODULES=1
				shift
				;;
			--no-host-modules=*) die "--no-host-modules is a boolean; use --no-host-modules (or --no-host-modules=1)" ;;
			*)
				# Only the kubectl role forwards arguments. A stray
				# argument on a node role would otherwise vanish
				# silently - e.g. `master --master-join=1` used to
				# quietly run kubeadm init instead of a join.
				[[ ${ENTRYPOINT_ROLE} == kubectl ]] \
					|| die "unknown argument '${1}' for role ${ENTRYPOINT_ROLE} (only the kubectl role takes passthrough arguments)"
				ROLE_ARGS+=("$1")
				shift
				;;
		esac
	done
}

# Validate the role, drop it from the args, then parse the flags: what
# remains is what the role receives.
case "${1:-}" in
	master | worker | lb | kubectl)
		ENTRYPOINT_ROLE="$1"
		shift
		;;
	*)
		die "usage: $0 {master|worker|lb|kubectl} [flags] [kubectl-args...]"
		;;
esac
parse_role_flags "$@"
# `--` bypasses the unknown-argument die above by design (kubectl needs the
# delimiter itself for `exec POD -- CMD`), so a node role that received one
# must still die here instead of silently ignoring the trailing args.
if [[ ${ENTRYPOINT_ROLE} != kubectl && ${#ROLE_ARGS[@]} -gt 0 ]]; then
	die "unknown argument '${ROLE_ARGS[0]}' for role ${ENTRYPOINT_ROLE} (only the kubectl role takes passthrough arguments)"
fi
"run_${ENTRYPOINT_ROLE}" "${ROLE_ARGS[@]}"

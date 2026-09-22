#!/usr/bin/env bash
#
# zek - Kubernetes node container.
#
# Roles:
#   master   kubeadm init + kubelet supervisor
#   worker   kubeadm join + kubelet supervisor
#   kubectl  kubectl client against the shared cluster config
#
# Persistence and host isolation:
#   - Everything lives on the container's own writable layer: node state
#     (kubelet, containerd, etcd) under /var/lib, /etc/kubernetes symlinked
#     onto it, and cluster state (admin.conf, token, CA hash, master IP) under
#     /etc/cluster. That survives docker stop/start, docker restart and host
#     reboots, and dies with the container on docker rm.
#   - The manager passes join credentials for a fresh worker as the JOIN_*
#     env vars; the /etc/cluster files are used as a fallback.
#   - Host effects are limited to in-memory kernel setup (loading modules the
#     host lacks and enabling a few sysctls); both are undone on shutdown and
#     nothing touches disk. Set NO_HOST_MODULES=1 to skip all host setup.
set -euo pipefail

readonly CLUSTER_DIR="${CLUSTER_DIR:-/etc/cluster}"
readonly NODENAME="${NODE_NAME:-$(hostname)}"
readonly POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
readonly KUBELET_CONFIG=/var/lib/kubelet/config.yaml
readonly KUBEADM_FLAGS=/var/lib/kubelet/kubeadm-flags.env
readonly KUBEADM_INIT_CONF=/etc/zek/kubeadm-init.yaml
readonly KUBEADM_JOIN_CONF=/etc/zek/kubeadm-join.yaml

CONTAINERD_PID=""
SUPERVISOR_PID=""
declare -A SYSCTL_BEFORE=()
HOST_MODULES_PRESENT=""

log() { echo "[zek] $*" >&2; }
die() {
	log "ERROR: $*"
	exit 1
}

cleanup() {
	# Undo the host-level kernel setup: restore sysctls and unload any modules
	# we loaded (only ones the host did not already have). Unloading may fail
	# while other processes still use them, which is fine.
	log "shutting down"
	[ -n "$CONTAINERD_PID" ] && kill "$CONTAINERD_PID" 2>/dev/null || true
	[ -n "$SUPERVISOR_PID" ] && kill "$SUPERVISOR_PID" 2>/dev/null || true
	for k in "${!SYSCTL_BEFORE[@]}"; do
		[ -n "${SYSCTL_BEFORE[$k]}" ] && sysctl -w "$k=${SYSCTL_BEFORE[$k]}" >/dev/null 2>&1 || true
	done
	for m in br_netfilter vxlan; do
		case " $HOST_MODULES_PRESENT " in
		*" $m "*) ;;
		*) rmmod "$m" 2>/dev/null || true ;;
		esac
	done
	exit 0
}
trap cleanup TERM INT

preflight_host() {
	# In-memory kernel setup only: it does not survive a reboot and touches no
	# disk. Skip entirely with NO_HOST_MODULES=1 if the host manages its own
	# modules (e.g. they were already loaded at boot).
	[ "${NO_HOST_MODULES:-0}" = 1 ] && return 0
	for m in br_netfilter vxlan; do
		if [ -d "/sys/module/$m" ]; then
			HOST_MODULES_PRESENT="$HOST_MODULES_PRESENT $m"
		else
			modprobe "$m" 2>/dev/null || true
		fi
	done
	for k in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables; do
		SYSCTL_BEFORE[$k]="$(sysctl -n "$k" 2>/dev/null || true)"
		sysctl -w "$k=1" 2>/dev/null || true
	done
}

ensure_resolv_conf() {
	# kubelet copies the node resolv.conf into pod sandboxes where 127.0.0.11
	# (Docker's embedded DNS) would be a per-sandbox loopback and fail. Extract
	# the real upstream IPs, skipping loopback/link-local stubs (e.g. a host
	# systemd-resolved 127.0.0.53 is not routable from our netns), and fall
	# back to public resolvers when nothing usable remains.
	local upstreams
	upstreams="${NODE_DNS:-}"
	if [ -z "$upstreams" ]; then
		upstreams="$(grep -oE '([0-9]+\.){3}[0-9]+' /etc/resolv.conf |
			grep -vE '^127\.|^169\.254\.' | sort -u | tr '\n' ' ')" || true
	fi
	[ -n "$upstreams" ] || upstreams="1.1.1.1 8.8.8.8"
	{
		echo "search ."
		for ns in $upstreams; do echo "nameserver $ns"; done
	} >/etc/resolv.conf
}

ensure_etc_kubernetes() {
	# kubeadm insists on /etc/kubernetes; keep it on the persistent /var/lib
	# volume so node state survives container removal.
	mkdir -p /var/lib/kubernetes
	ln -sfn /var/lib/kubernetes /etc/kubernetes
}

start_containerd() {
	[ -f /etc/containerd/config.toml ] || containerd config default >/etc/containerd/config.toml
	# Search both the Alpine-provided and user-installed CNI binaries.
	sed -i "s|bin_dirs = \[.*\]|bin_dirs = ['/opt/cni/bin', '/usr/libexec/cni']|" /etc/containerd/config.toml
	# /var/lib lives on the container's overlay rootfs (no volume), and overlay
	# cannot be nested on overlay, so use the native snapshotter instead.
	sed -i "s|^\([[:space:]]*snapshotter = \).*|\1'native'|" /etc/containerd/config.toml
	# containerd >=2.3 the transfer service only accepts unpack requests whose
	# snapshotter is listed in its unpack_config; the default just knows the
	# default (overlayfs) one. Without this, every CRI pull - kubeadm, crictl,
	# kubelet - fails with "no unpack platforms defined".
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
	containerd >/var/log/containerd.log 2>&1 &
	CONTAINERD_PID=$!
	for _ in $(seq 1 60); do
		[ -S /run/containerd/containerd.sock ] && return 0
		sleep 1
	done
	die "containerd did not start (see /var/log/containerd.log)"
}

cleanup_stale_cri() {
	# Purge dead pods/sandboxes left by a previous node instance so kubelet
	# recreates them fresh; images are kept.
	log "purging stale containers from previous node instance"
	crictl rmp -f -a >/dev/null 2>&1 || true
	crictl rm -f -a >/dev/null 2>&1 || true
}

import_k8s_images() {
	# The image build preloaded the kubeadm images (apiserver, etcd, scheduler,
	# controller-manager, coredns, kube-proxy, pause) as tarballs under
	# /opt/zek/images. Import them into the CRI image store (content only,
	# --no-unpack: no mounts needed, unpacking happens lazily when the kubelet
	# first pulls them). Only runs on a fresh node, once.
	if ! command -v ctr >/dev/null 2>&1; then
		log "WARNING: ctr not installed; skipping kubeadm image preload"
		return 0
	fi
	log "importing preloaded kubeadm images"
	local t
	for t in /opt/zek/images/*.tar; do
		[ -e "$t" ] || continue
		ctr --namespace k8s.io images import --no-unpack "$t" >/dev/null 2>&1 || log "WARNING: failed to import $t"
	done
}

master_ip() {
	ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1
}

ca_hash() {
	openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt |
		openssl pkey -pubin -outform der 2>/dev/null |
		openssl dgst -sha256 -hex | sed 's/^.*= //'
}

write_kubeadm_init_conf() {
	mkdir -p /etc/zek
	cat >"$KUBEADM_INIT_CONF" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
  bindPort: 6443
nodeRegistration:
  name: ${NODENAME}
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: ${POD_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: cgroupfs
EOF
}

write_kubeadm_join_conf() {
	mkdir -p /etc/zek
	cat >"$KUBEADM_JOIN_CONF" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    token: ${TOKEN}
    apiServerEndpoint: ${MASTER_IP}:6443
    caCertHashes:
    - sha256:${CA_HASH}
nodeRegistration:
  name: ${NODENAME}
  criSocket: unix:///run/containerd/containerd.sock
EOF
}

patch_kube_proxy() {
	# In a container netns kube-proxy cannot grow the global conntrack table
	# (EACCES); disable its auto-tuning via the ConfigMap.
	log "disabling kube-proxy conntrack tuning"
	local dir=/etc/zek/kube-proxy
	mkdir -p "$dir"
	export KUBECONFIG=/etc/kubernetes/admin.conf
	kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' >"$dir/config.conf"
	kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.kubeconfig\.conf}' >"$dir/kubeconfig.conf"
	[ -s "$dir/config.conf" ] || return 0
	sed -i -e 's/^\(  maxPerCore: \)null/\10/' -e 's/^\(  min: \)null/\10/' "$dir/config.conf"
	kubectl -n kube-system create configmap kube-proxy \
		--from-file=config.conf="$dir/config.conf" \
		--from-file=kubeconfig.conf="$dir/kubeconfig.conf" \
		--dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
	kubectl -n kube-system rollout restart daemonset kube-proxy >/dev/null 2>&1 || true
}

wait_for_cluster_files() {
	log "waiting for cluster config on master ($CLUSTER_DIR)"
	for _ in $(seq 1 300); do
		[ -f "$CLUSTER_DIR/token" ] && [ -f "$CLUSTER_DIR/ca-hash" ] && [ -f "$CLUSTER_DIR/master-ip" ] &&
			return 0
		sleep 2
	done
	die "timed out waiting for cluster config in $CLUSTER_DIR"
}

# Keep kubelet alive and restart it when it exits. kubeadm writes its config
# and flags file, and without systemd we feed the kubeconfig args ourselves.
# config.yaml appearing marks kubeadm init/join as done; init does not put
# kubelet.conf on kubelet's default path, so it must always be passed on.
kubelet_supervisor() {
	trap 'exit 0' TERM INT
	while :; do
		if [ -f "$KUBELET_CONFIG" ]; then
			local args=""
			if [ -f "$KUBEADM_FLAGS" ]; then
				source "$KUBEADM_FLAGS"
				args="${KUBELET_KUBEADM_ARGS:-}"
			fi
			if [ -f /etc/kubernetes/bootstrap-kubelet.conf ]; then
				args="$args --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
			elif [ -f /etc/kubernetes/kubelet.conf ]; then
				args="$args --kubeconfig=/etc/kubernetes/kubelet.conf"
			fi
			kubelet --config "$KUBELET_CONFIG" --hostname-override "$NODENAME" \
				--fail-swap-on=false --v=2 $args &
			local pid=$!
			log "kubelet running (pid $pid)"
			wait "$pid" 2>/dev/null || true
			log "kubelet exited, restarting"
		fi
		sleep 2
	done
}

ensure_cni_dirs() {
	# Nodes start with no CNI; the user installs one whose installer runs as a
	# non-root pod user (e.g. calico uses uid 10001) and drops binaries/config
	# onto the node. Pre-create those paths world-writable so it works.
	for d in /etc/cni/net.d /opt/cni/bin; do mkdir -p "$d" && chmod 0777 "$d"; done
}

ensure_shared_mounts() {
	# Calico's eBPF bootstrap and cilium mount host fs types (bpffs) into pods
	# with mount propagation; kubelet rejects that unless the parent mounts are
	# shared. Applies to this container's mount namespace only.
	mount --make-rshared / 2>/dev/null || true
	mount --make-rshared /sys 2>/dev/null || true
	mount --make-rshared /run 2>/dev/null || true
}

ensure_bpffs() {
	# Pre-mount the BPF filesystem so eBPF CNIs (cilium, calico eBPF) start
	# cleanly instead of racing to mount it in-band on every start. A no-op
	# when a CNI already mounted it or the host lacks BPF support.
	grep -q " /sys/fs/bpf " /proc/mounts 2>/dev/null && return 0
	mkdir -p /sys/fs/bpf
	mount -t bpf bpf /sys/fs/bpf 2>/dev/null ||
		log "WARNING: bpffs not mounted at /sys/fs/bpf (BPF-based CNIs may need it)"
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

run_master() {
	node_setup

	# The token we publish at the very end doubles as the "initialized" marker.
	if [ -f "$CLUSTER_DIR/token" ]; then
		log "control plane already initialized, resuming"
	else
		local ip_addr
		ip_addr="$(master_ip)"
		log "initializing control plane on ${NODENAME} (${ip_addr})"
		mkdir -p "$CLUSTER_DIR"
		import_k8s_images
		MASTER_IP="$ip_addr"
		write_kubeadm_init_conf
		kubeadm init --config "$KUBEADM_INIT_CONF" --ignore-preflight-errors=all || die "kubeadm init failed"

		export KUBECONFIG=/etc/kubernetes/admin.conf
		patch_kube_proxy

		log "publishing join credentials to $CLUSTER_DIR"
		kubeadm token create --ttl 0 | tr -d '\n' >"$CLUSTER_DIR/token"
		cp /etc/kubernetes/admin.conf "$CLUSTER_DIR/admin.conf"
		echo "$ip_addr" >"$CLUSTER_DIR/master-ip"
		ca_hash >"$CLUSTER_DIR/ca-hash"
		log "control plane ready (token: $(cat "$CLUSTER_DIR/token"))"
		log "no CNI installed; nodes are NotReady until you install one (flannel, calico, cilium, ...)"
	fi

	wait "$SUPERVISOR_PID"
}

run_worker() {
	node_setup

	if [ -f /etc/kubernetes/kubelet.conf ]; then
		log "node already joined, resuming"
	else
		if [ -n "${JOIN_TOKEN:-}${JOIN_CA_HASH:-}${JOIN_MASTER_IP:-}" ]; then
			TOKEN="$JOIN_TOKEN"
			CA_HASH="$JOIN_CA_HASH"
			MASTER_IP="$JOIN_MASTER_IP"
		else
			wait_for_cluster_files
			TOKEN="$(cat "$CLUSTER_DIR/token")"
			CA_HASH="$(cat "$CLUSTER_DIR/ca-hash")"
			MASTER_IP="$(cat "$CLUSTER_DIR/master-ip")"
		fi
		log "joining ${NODENAME} to ${MASTER_IP}"
		import_k8s_images
		write_kubeadm_join_conf
		kubeadm join --config "$KUBEADM_JOIN_CONF" --ignore-preflight-errors=all || die "kubeadm join failed"
	fi

	wait "$SUPERVISOR_PID"
}

run_kubectl() {
	log "waiting for cluster config on master ($CLUSTER_DIR)"
	for _ in $(seq 1 300); do
		[ -f "$CLUSTER_DIR/admin.conf" ] && break
		sleep 2
	done
	[ -f "$CLUSTER_DIR/admin.conf" ] || die "no admin.conf found; is the master running?"
	export KUBECONFIG="$CLUSTER_DIR/admin.conf"
	[ $# -eq 0 ] && exec bash
	exec kubectl "$@"
}

case "${1:-}" in
master) shift && run_master "$@" ;;
worker) shift && run_worker "$@" ;;
kubectl) shift && run_kubectl "$@" ;;
*) die "usage: $0 {master|worker|kubectl [kubectl-args...]}" ;;
esac

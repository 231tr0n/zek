#!/usr/bin/env bash
#
# e2e - end-to-end tests for the zek image.
#
# Builds nothing: point it at an image that already exists (make build).
# Every test creates its own cluster (e2e-<test>), asserts, then destroys it.
#
# Usage:
#   ./e2e.sh [test ...]      run the given tests, or all of them
#
# Tests:
#   multi-master   3 masters + 1 worker: HA init/join behind the LB, 3 etcd
#                  members, quorum survives docker stop/start of a master
#   multi-worker   1 master + 3 workers: every node's kubelet/containerd
#                  work (hostNetwork DaemonSet lands on all 4 nodes)
#   flannel        install flannel, nodes go Ready, coredns rolls out,
#                  cross-node pod-to-pod ping
#   cilium         same with cilium (cilium CLI downloaded on demand)
#   istio          flannel + istio-cni, sidecar injection works and the
#                  istio-init network setup stays absent (istioctl
#                  downloaded on demand)
#   persistence    flannel + a workload, then recovery from: docker
#                  stop/start of every node at once, a stopped worker, a
#                  restarted master and `zek down`/`up` - same nodes
#                  (UIDs), workload Ready again after each cycle
#
# Env:
#   ZEK_IMAGE              image under test (default zek:latest)
#   ZEK_TIMEOUT            per-wait budget inside zek.sh (default 600)
#   ZEK_E2E_TIMEOUT        budget for kubectl waits (default 1200; large
#                          image pulls on a slow day can eat 10+ minutes)
#   ZEK_E2E_TESTS          comma separated test list (same as the args)
#   ZEK_E2E_KEEP_ON_FAIL   1 = leave the failed cluster running for debugging
#   CILIUM_VERSION         cilium version to install (default v1.20.2)
#   ISTIO_VERSION          istio version to download (default latest)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ALL_TESTS=(multi-master multi-worker flannel cilium istio persistence)

export ZEK_IMAGE="${ZEK_IMAGE:-zek:latest}"
export ZEK_TIMEOUT="${ZEK_TIMEOUT:-600}"
ZEK_E2E_TIMEOUT="${ZEK_E2E_TIMEOUT:-1200}"
CILIUM_VERSION="${CILIUM_VERSION:-v1.20.2}"
READY_POLL=10

log() { printf '\n[e2e] %s\n' "$*"; }
die() {
	printf '[e2e] ERROR: %s\n' "$*" >&2
	exit 1
}
fail() {
	printf '\n[e2e] FAIL: %s\n' "$*" >&2
	exit 1
}

usage() {
	die "usage: $0 [multi-master|multi-worker|flannel|cilium|istio|persistence]..."
}

# --- test selection ---------------------------------------------------------
requested=()
if [[ $# -gt 0 ]]; then
	requested=("$@")
elif [[ -n ${ZEK_E2E_TESTS:-} ]]; then
	IFS=',' read -ra requested <<<"${ZEK_E2E_TESTS}"
else
	requested=("${ALL_TESTS[@]}")
fi
for t in "${requested[@]}"; do
	case " ${ALL_TESTS[*]} " in
	*" ${t} "*) ;;
	*) usage ;;
	esac
done

docker image inspect "${ZEK_IMAGE}" >/dev/null 2>&1 ||
	die "image ${ZEK_IMAGE} not found (run: make build)"

# --- scratch space for downloaded CLIs and kubeconfigs ----------------------
WORK_DIR=$(mktemp -d)
BIN_DIR="${WORK_DIR}/bin"
mkdir -p "${BIN_DIR}"
PATH="${BIN_DIR}:${PATH}"
export PATH

CURRENT=""
CREATED=()

# --- helpers ----------------------------------------------------------------
zk() { ./zek.sh -c "$1" "${@:2}"; }

up() { zk "$1" up --workers "$2" --masters "$3"; }

destroy() { ./zek.sh -c "$1" destroy >/dev/null 2>&1 || true; }

# A static-IP start can race the previous endpoint's cleanup and fail
# with "Address already in use"; retry before giving up.
start_containers() { # name...
	local out
	for _ in {1..10}; do
		if out=$(docker start "$@" 2>&1); then
			return 0
		fi
		sleep 2
	done
	printf '%s\n' "${out}" >&2
	return 1
}

running_count() { docker ps --format '{{.Names}}' -f "network=$1-net" | wc -l; }

cluster_containers() { docker ps -a --format '{{.Names}}' -f "network=$1-net"; }

assert_eq() { # desc want got
	[[ $2 == "$3" ]] || fail "$1: want '$2', got '$3'"
}

assert_cmd() { # desc want cmd args... (runs cmd, fails hard if it errors)
	local desc=${1} want=${2} got
	shift 2
	got=$("$@") || fail "${desc}: '$*' failed"
	assert_eq "${desc}" "${want}" "${got}"
}

wait_for() { # desc timeout-secs func args...
	local desc=$1 t=$2 deadline
	shift 2
	deadline=$((SECONDS + t))
	until "$@" >/dev/null 2>&1; do
		[[ ${SECONDS} -lt ${deadline} ]] || fail "timed out after ${t}s waiting for: ${desc}"
		sleep 5
	done
	log "ok: ${desc}"
}

readyz_ok() { zk "$1" kubectl get --raw='/readyz' 2>/dev/null | grep -qx ok; }

nodes_ready_quick() {
	zk "$1" kubectl wait --for=condition=Ready node --all \
		--timeout="${READY_POLL}s" >/dev/null 2>&1
}

wait_nodes_ready() {
	wait_for "all nodes Ready on $1" "${ZEK_E2E_TIMEOUT}" nodes_ready_quick "$1"
}

node_status_is() { # cluster node want(True|False)
	local got
	# shellcheck disable=SC2310
	got=$(zk "$1" kubectl get node "$2" \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || return 1
	# A dead kubelet's node flips Ready=Unknown after the grace period and
	# stays there, so wanting False means "anything but Ready".
	if [[ $3 == False ]]; then
		[[ ${got} != True ]]
	else
		[[ ${got} == "$3" ]]
	fi
}

node_count() { zk "$1" kubectl get nodes --no-headers | wc -l; }

ready_false_count() {
	# shellcheck disable=SC2310
	zk "$1" kubectl get nodes \
		-o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
		grep -c False || true
}

node_uids() {
	zk "$1" kubectl get nodes \
		-o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}{"\n"}{end}' | sort
}

ns_pod_count() { # cluster 'name-regex'
	# shellcheck disable=SC2310
	zk "$1" kubectl -n kube-system get pods --no-headers | grep -cE "$2" || true
}

pod_phase() { # cluster pod-name
	zk "$1" kubectl -n kube-system get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null
}

container_running() {
	local state
	state=$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) || state=false
	[[ ${state} == true ]]
}

# Is the apiserver inside a master container serving? (no CNI needed)
master_readyz() { # cluster master-index
	docker exec "${1}-master-${2}" curl -skf https://127.0.0.1:6443/readyz 2>/dev/null |
		grep -qx ok
}

web_info() {
	zk "$1" kubectl -n default get pod -l app=web \
		-o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}@{.spec.nodeName}{"\n"}{end}'
}

kubeconfig() { # cluster -> prints path to its admin.conf
	local out="${WORK_DIR}/kubeconfig-$1.conf"
	docker exec "$1-master-1" cat /etc/cluster/admin.conf >"${out}"
	printf '%s\n' "${out}"
}

wait_coredns() {
	zk "$1" kubectl -n kube-system rollout status deploy/coredns \
		--timeout="${ZEK_E2E_TIMEOUT}s"
}

# Two busybox pods pinned to different workers, pinged across the overlay.
netcheck() {
	local c=$1 ip_a ip_b
	zk "${c}" kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: net-a
spec:
  nodeSelector:
    kubernetes.io/hostname: ${c}-worker-1
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.36
    command: [sleep, "600"]
EOF
	zk "${c}" kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: net-b
spec:
  nodeSelector:
    kubernetes.io/hostname: ${c}-worker-2
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.36
    command: [sleep, "600"]
EOF
	zk "${c}" kubectl wait --for=condition=Ready pod/net-a pod/net-b \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	ip_a=$(zk "${c}" kubectl get pod net-a -o jsonpath='{.status.podIP}')
	ip_b=$(zk "${c}" kubectl get pod net-b -o jsonpath='{.status.podIP}')
	log "ping ${ip_a} -> ${ip_b}"
	# shellcheck disable=SC2310
	zk "${c}" kubectl exec net-a -- ping -c 3 "${ip_b}" >/dev/null ||
		fail "${c}: cross-node ping net-a -> net-b failed"
	log "ping ${ip_b} -> ${ip_a}"
	# shellcheck disable=SC2310
	zk "${c}" kubectl exec net-b -- ping -c 3 "${ip_a}" >/dev/null ||
		fail "${c}: cross-node ping net-b -> net-a failed"
	zk "${c}" kubectl delete pod net-a net-b --wait=false >/dev/null
}

apply_flannel() {
	local manifest
	manifest=$(curl -fsSL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml) ||
		die "flannel manifest download failed"
	zk "$1" kubectl apply -f - <<<"${manifest}"
}

ARCH=""
arch=$(uname -m)
case "${arch}" in
x86_64) ARCH=amd64 ;;
aarch64 | arm64) ARCH=arm64 ;;
*) die "unsupported architecture: ${arch}" ;;
esac

ensure_cilium() {
	command -v cilium >/dev/null 2>&1 && return 0
	local url tag
	log "downloading cilium CLI"
	url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
		https://github.com/cilium/cilium-cli/releases/latest)
	tag=${url##*/}
	curl -fsSL -o "${WORK_DIR}/cilium.tar.gz" \
		"https://github.com/cilium/cilium-cli/releases/download/${tag}/cilium-linux-${ARCH}.tar.gz"
	tar -xzf "${WORK_DIR}/cilium.tar.gz" -C "${BIN_DIR}"
}

ensure_istioctl() {
	command -v istioctl >/dev/null 2>&1 && return 0
	local target_arch dir
	log "downloading istioctl${ISTIO_VERSION:+ ${ISTIO_VERSION}}"
	target_arch=$(uname -m)
	[[ ${target_arch} == aarch64 ]] && target_arch=arm64
	local -a envs=(TARGET_ARCH="${target_arch}")
	[[ -n ${ISTIO_VERSION:-} ]] && envs+=(ISTIO_VERSION="${ISTIO_VERSION}")
	(cd "${WORK_DIR}" && curl -fsSL https://istio.io/downloadIstio | env "${envs[@]}" sh)
	for dir in "${WORK_DIR}"/istio-*; do
		if [[ -x "${dir}/bin/istioctl" ]]; then
			ln -sf "${dir}/bin/istioctl" "${BIN_DIR}/istioctl"
			return 0
		fi
	done
	die "istioctl download failed"
}

diag() {
	local c=$1 n list
	log "================ diagnostics for ${c} ================"
	./zek.sh -c "${c}" status || true
	./zek.sh -c "${c}" kubectl get nodes -o wide || true
	./zek.sh -c "${c}" kubectl get pods -A -o wide || true
	./zek.sh -c "${c}" kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null |
		tail -50 || true
	# shellcheck disable=SC2310
	list=$(cluster_containers "${c}") || list=""
	while IFS= read -r n; do
		[[ -n ${n} ]] || continue
		log "----- last 30 log lines of ${n} -----"
		docker logs --tail 30 "${n}" 2>&1 | tail -30 || true
	done <<<"${list}"
	log "=============== end diagnostics for ${c} ================"
}

cleanup() {
	local st=$? c
	trap - EXIT
	if [[ ${st} -ne 0 ]] && [[ -n ${CURRENT} ]]; then
		diag "${CURRENT}"
	fi
	for c in "${CREATED[@]:-}"; do
		[[ -n ${c} ]] || continue
		if [[ ${st} -ne 0 ]] && [[ ${c} == "${CURRENT}" ]] &&
			[[ ${ZEK_E2E_KEEP_ON_FAIL:-0} == 1 ]]; then
			log "keeping ${c} running (ZEK_E2E_KEEP_ON_FAIL=1)"
			continue
		fi
		destroy "${c}"
	done
	rm -rf "${WORK_DIR}"
	exit "${st}"
}
trap cleanup EXIT

# --- tests ------------------------------------------------------------------

test_multi_master() {
	local c=$1 i
	up "${c}" 1 3
	assert_cmd "${c}: node count" 4 node_count "${c}"
	assert_cmd "${c}: etcd members" 3 ns_pod_count "${c}" '^etcd-'
	for i in 1 2 3; do
		assert_cmd "${c}: apiserver on master-${i}" Running pod_phase "${c}" "kube-apiserver-${c}-master-${i}"
		assert_cmd "${c}: etcd on master-${i}" Running pod_phase "${c}" "etcd-${c}-master-${i}"
	done
	# shellcheck disable=SC2310
	container_running "${c}-lb" || fail "${c}: load balancer is not running"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"

	log "${c}: HA - stop master-3, the cluster must keep serving"
	docker stop "${c}-master-3" >/dev/null
	wait_for "${c}: API serves with master-3 stopped (etcd quorum)" 120 readyz_ok "${c}"
	start_containers "${c}-master-3"
	wait_for "${c}: apiserver on master-3 serving again" 300 master_readyz "${c}" 3
	wait_for "${c}: control plane readyz after restart" 120 readyz_ok "${c}"
}

test_multi_worker() {
	local c=$1
	up "${c}" 3 1
	assert_cmd "${c}: node count" 4 node_count "${c}"
	assert_cmd "${c}: nodes NotReady but kubelets reporting" 4 ready_false_count "${c}"

	# hostNetwork pods need no CNI, so this DaemonSet proves kubelet +
	# containerd work on every node even before a CNI is installed.
	log "${c}: hostNetwork DaemonSet on all 4 nodes"
	zk "${c}" kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: e2e-hostcheck
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: e2e-hostcheck
  template:
    metadata:
      labels:
        app: e2e-hostcheck
    spec:
      hostNetwork: true
      tolerations:
      - operator: Exists
      containers:
      - name: check
        image: busybox:1.36
        command: [sleep, "3600"]
EOF
	zk "${c}" kubectl -n kube-system rollout status ds/e2e-hostcheck \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

test_flannel() {
	local c=$1
	up "${c}" 2 1
	assert_cmd "${c}: node count" 3 node_count "${c}"
	log "${c}: installing flannel"
	apply_flannel "${c}"
	wait_nodes_ready "${c}"
	wait_coredns "${c}"
	netcheck "${c}"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

test_cilium() {
	local c=$1 kc
	up "${c}" 2 1
	assert_cmd "${c}: node count" 3 node_count "${c}"
	ensure_cilium
	kc=$(kubeconfig "${c}")
	log "${c}: installing cilium ${CILIUM_VERSION}"
	if [[ -n ${CILIUM_VERSION} ]]; then
		KUBECONFIG="${kc}" cilium install --version "${CILIUM_VERSION}"
	else
		KUBECONFIG="${kc}" cilium install
	fi
	# Image pulls of the ~260MB cilium images can eat most of the CLI's
	# default 5m wait; use the same budget as every other kubectl wait.
	KUBECONFIG="${kc}" cilium status --wait --wait-duration="${ZEK_E2E_TIMEOUT}s"
	wait_nodes_ready "${c}"
	wait_coredns "${c}"
	netcheck "${c}"
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

test_istio() {
	local c=$1 kc containers inits
	up "${c}" 1 1
	assert_cmd "${c}: node count" 2 node_count "${c}"

	# A base CNI first: istio-cni is a chained plugin and the test app
	# needs working pod networking like any other workload.
	log "${c}: installing flannel"
	apply_flannel "${c}"
	wait_nodes_ready "${c}"

	ensure_istioctl
	kc=$(kubeconfig "${c}")
	log "${c}: installing istio with istio-cni"
	istioctl install --set profile=default --set components.cni.enabled=true \
		--set values.cni.enabled=true --kubeconfig "${kc}" -y
	zk "${c}" kubectl -n istio-system rollout status deploy/istiod \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	# The CNI DaemonSet ships as istio-cni-node (renamed from istio-cni).
	zk "${c}" kubectl -n istio-system rollout status ds/istio-cni-node \
		--timeout="${ZEK_E2E_TIMEOUT}s"

	log "${c}: sidecar injection (istio-injection=enabled)"
	zk "${c}" kubectl create namespace zek-e2e
	zk "${c}" kubectl label namespace zek-e2e istio-injection=enabled
	zk "${c}" kubectl -n zek-e2e apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  nodeSelector:
    kubernetes.io/hostname: ${c}-worker-1
  restartPolicy: Never
  containers:
  - name: app
    image: busybox:1.36
    command: [sleep, "600"]
EOF
	zk "${c}" kubectl -n zek-e2e wait --for=condition=Ready pod/app \
		--timeout="${ZEK_E2E_TIMEOUT}s"
	# Current istio injects the sidecar as a native sidecar (an
	# initContainer with restartPolicy Always), so collect names from
	# both container lists before asserting.
	containers=$(zk "${c}" kubectl -n zek-e2e get pod app \
		-o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}{range .spec.initContainers[*]}{.name}{" "}{end}')
	case " ${containers} " in
	*" istio-proxy "*) ;;
	*) fail "${c}: istio-proxy sidecar not injected (containers: '${containers}')" ;;
	esac
	# istio-cni replaces the istio-init network-setup container; it must
	# be absent (istio-validation and the native sidecar may remain).
	inits=$(zk "${c}" kubectl -n zek-e2e get pod app \
		-o jsonpath='{range .spec.initContainers[*]}{.name}{" "}{end}')
	case " ${inits} " in
	*" istio-init "*)
		fail "${c}: istio-init present, istio-cni should avoid it (inits: '${inits}')"
		;;
	*) ;;
	esac
	wait_for "${c}: control plane readyz" 120 readyz_ok "${c}"
}

test_persistence() {
	local c=$1 uids web
	up "${c}" 2 1
	log "${c}: installing flannel + workload"
	apply_flannel "${c}"
	wait_nodes_ready "${c}"
	zk "${c}" kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: busybox:1.36
        command: [sleep, "3600"]
EOF
	zk "${c}" kubectl rollout status deploy/web --timeout="${ZEK_E2E_TIMEOUT}s"
	uids=$(node_uids "${c}")
	web=$(web_info "${c}")
	[[ -n ${web} ]] || fail "${c}: web pod not found"

	assert_state() { # what
		# recovery first (the API may be down right after a restart),
		# then the identity checks that must not change
		wait_for "${c}: readyz after $1" 300 readyz_ok "${c}"
		wait_nodes_ready "${c}"
		zk "${c}" kubectl rollout status deploy/web --timeout="${ZEK_E2E_TIMEOUT}s"
		assert_cmd "${c}: node UIDs after ${1}" "${uids}" node_uids "${c}"
		assert_cmd "${c}: web pod after ${1}" "${web}" web_info "${c}"
	}

	log "${c}: docker stop + start every node at once"
	local -a names=()
	local list
	# shellcheck disable=SC2310
	list=$(cluster_containers "${c}") || fail "${c}: cannot list containers"
	if [[ -n ${list} ]]; then
		mapfile -t names <<<"${list}"
	fi
	[[ ${#names[@]} -ge 3 ]] || fail "${c}: expected >=3 containers, got ${#names[@]}"
	docker stop "${names[@]}" >/dev/null
	assert_cmd "${c}: all containers stopped" 0 running_count "${c}"
	# Start in dependency-safe order (lb, masters, workers) like zek's
	# own restart: workers use dynamic IPs, so a worker starting first
	# can claim a stopped master's static address and leave the master
	# failing with "Address already in use".
	local role n
	local -a wave=()
	for role in lb master worker; do
		wave=()
		for n in "${names[@]}"; do
			if [[ ${n} == *-"${role}" || ${n} == *-"${role}"-[0-9]* ]]; then
				wave+=("${n}")
			fi
		done
		if [[ ${#wave[@]} -gt 0 ]]; then
			start_containers "${wave[@]}"
		fi
	done
	assert_state "full stop/start"

	log "${c}: docker stop + start a single worker"
	docker stop "${c}-worker-1" >/dev/null
	wait_for "${c}: worker-1 reports NotReady" 300 node_status_is "${c}" \
		"${c}-worker-1" False
	start_containers "${c}-worker-1"
	wait_for "${c}: worker-1 back to Ready" "${ZEK_E2E_TIMEOUT}" node_status_is "${c}" \
		"${c}-worker-1" True
	assert_state "worker restart"

	log "${c}: docker restart the master"
	docker restart "${c}-master-1" >/dev/null
	assert_state "master restart"

	log "${c}: zek down + zek up"
	zk "${c}" down
	assert_cmd "${c}: down stops everything" 0 running_count "${c}"
	zk "${c}" up
	assert_state "zek down/up"
}

# --- runner -----------------------------------------------------------------
# Drop leftovers of earlier runs first: `up` would otherwise restart a stale
# cluster (topology fixed at creation) instead of creating a fresh one.
stale=$(docker ps -a --format '{{.Names}}' |
	sed -E 's/-(master|worker)-[0-9]+$//; s/-lb$//' |
	grep -E '^e2e-' | sort -u || true)
if [[ -n ${stale} ]]; then
	while IFS= read -r c; do
		[[ -n ${c} ]] || continue
		log "removing leftover cluster ${c}"
		destroy "${c}"
	done <<<"${stale}"
fi

for t in "${requested[@]}"; do
	fn=${t//-/_}
	CURRENT="e2e-${t}"
	CREATED+=("${CURRENT}")
	log "======== test ${t} (cluster ${CURRENT}) ========"
	"test_${fn}" "${CURRENT}"
	destroy "${CURRENT}"
	CURRENT=""
	log "======== test ${t}: PASSED ========"
done

log "all tests passed: ${requested[*]}"

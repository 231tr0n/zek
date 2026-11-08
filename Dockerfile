ARG ALPINE_VERSION
FROM alpine:${ALPINE_VERSION}

ARG KUBERNETES_VERSION
ARG TARGETARCH

# gcompat: the kubeadm/kubelet/kubectl binaries from dl.k8s.io are
# glibc-linked; on alpine's musl they run through gcompat's loader (a
# comm read of kubelet therefore shows ld-musl-x86_64, see
# kubelet_running in e2e.sh).
# apk packages float on purpose (only the base ALPINE_VERSION and the k8s
# binaries below are pinned); bump the base image to move them forward.
# Heredoc form on purpose: BuildKit logs a multi-line RUN as one giant
# joined line, unreadable for 30+ packages. No `set -x` in the body for
# the same reason (it would echo that line back).
RUN <<'EOF'
# Single line on purpose: keeps the package list diffable, and the build
# log only ever shows the short `RUN <<'EOF'` header either way.
apk add --no-cache bash ca-certificates containerd containerd-ctr runc cni-plugins iptables ip6tables nftables cri-tools haproxy gcompat coreutils findutils grep gawk sed diffutils procps-ng curl inetutils-telnet netcat-openbsd traceroute bind-tools openssh-client mtr iproute2 iputils ethtool nfs-utils socat conntrack-tools ebtables openssl kmod ipset tar lsof strace tcpdump jq yq less vim tree file
EOF

# The base CNI plugins ship in /usr/libexec/cni; symlink /opt/cni/bin to it so
# anything a user's CNI installs there is also visible to containerd.
RUN mkdir -p /opt/cni && ln -sfn /usr/libexec/cni /opt/cni/bin

RUN <<'EOF'
# KUBERNETES_VERSION comes from the Makefile's --build-arg; TARGETARCH
# is BuildKit's automatic platform argument (the ARG TARGETARCH above
# needs no --build-arg). Fail with a clear message instead of set -u's
# bare error when one is missing.
KUBERNETES_VERSION=${KUBERNETES_VERSION:?KUBERNETES_VERSION is required}
TARGETARCH=${TARGETARCH:?TARGETARCH is required}
set -eux
# Bump KUBERNETES_VERSION in the Makefile to move to a newer release.
# No network resolution of "latest" at build time.
for bin in kubectl kubeadm kubelet; do
	curl -fsSL --retry 5 --retry-all-errors -o "/usr/local/bin/${bin}" "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${TARGETARCH}/${bin}"
	chmod +x "/usr/local/bin/${bin}"
done
# Preload the kubeadm images so init/join needs no registry at runtime. The
# containerd store built here stays in the image layer; every node container
# starts containerd against it. containerd (apk) starts fine unprivileged and
# content fetch is plain file I/O, so no unpacking/mounting happens here.
# Minimal config for the build-time image preload only; at runtime
# entrypoint.sh reuses this file and applies its own tweaks (CNI bin_dirs,
# native unpack_config) on top, so only the snapshotter matters here.
containerd config default > /etc/containerd/config.toml
sed -i "s|^\([[:space:]]*snapshotter = \).*|\1'native'|" /etc/containerd/config.toml
containerd > /dev/null 2>&1 &
CONTAINERD_PID=$!
for _ in $(seq 1 60); do
	[ -S /run/containerd/containerd.sock ] && break
	sleep 1
done
[ -S /run/containerd/containerd.sock ]
images=$(kubeadm config images list --kubernetes-version "${KUBERNETES_VERSION}") || exit 1
# Unquoted split on purpose: the image list is machine-generated refs
# without spaces, one per line.
# ctr draws its download progress on stdout (ANSI escapes and carriage
# returns, unreadable in a log): drop it and keep stderr, which is where a
# failed fetch publishes its reason.
for image in ${images}; do
	ctr --namespace k8s.io content fetch --platform "linux/${TARGETARCH}" "${image}" > /dev/null
done
kill "${CONTAINERD_PID}"
kubeadm version -o short
EOF

COPY entrypoint.sh /entrypoint.sh

# Advisory metadata only: docker never restarts or stops a container for
# reporting unhealthy (restart policies ignore it; only Swarm/compose
# consumes it), so .State-driven logic and `docker ps` running/exited are
# unaffected. It probes the local daemons, never the cluster: a node is
# NotReady until the user installs a CNI, workers hold no admin kubeconfig,
# and an API outage would label healthy containers bad. lb -> haproxy's stats
# page; nodes -> containerd alive AND kubelet's healthz (both started by
# entrypoint.sh, kubelet under its supervisor). The 120s start period
# covers daemon startup; a slow kubeadm init/join can still take longer,
# and the verdict is advisory. Node checks come first so a process bound to
# :8404 inside a node cannot mask a dead containerd/kubelet.
# The continuation lines stay indented: dockerfmt -i 0 would otherwise
# unindent them along with the heredoc bodies.
# dockerfmt-ignore
HEALTHCHECK --interval=10s --timeout=5s --start-period=120s --retries=3 \
    CMD { pgrep -x containerd > /dev/null && curl -sf -m 2 http://127.0.0.1:10248/healthz > /dev/null; } || \
    curl -sf -m 2 http://127.0.0.1:8404/ > /dev/null

ENTRYPOINT ["/entrypoint.sh"]

ARG ALPINE_VERSION
FROM alpine:${ALPINE_VERSION}

ARG KUBERNETES_VERSION
ARG TARGETARCH

RUN apk add --no-cache \
    bash ca-certificates containerd containerd-ctr runc cni-plugins iptables ip6tables nftables cri-tools \
    gcompat \
    coreutils findutils grep gawk sed diffutils \
    procps-ng \
    curl inetutils-telnet netcat-openbsd traceroute bind-tools openssh-client mtr \
    iproute2 iputils ethtool socat conntrack-tools ebtables \
    openssl kmod ipset tar \
    lsof strace tcpdump jq yq less vim tree file

# The base CNI plugins ship in /usr/libexec/cni; symlink /opt/cni/bin to it so
# anything a user's CNI installs there is also visible to containerd.
RUN mkdir -p /opt/cni && ln -sfn /usr/libexec/cni /opt/cni/bin

RUN <<'EOF'
set -eux
# KUBERNETES_VERSION comes from the build (Makefile passes it); bump it there
# to move to a newer release. No network resolution of "latest" at build time.
for bin in kubectl kubeadm kubelet; do
	curl -fsSL --retry 5 --retry-all-errors -o "/usr/local/bin/${bin}" "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${TARGETARCH}/${bin}"
	chmod +x "/usr/local/bin/${bin}"
done
# Preload the kubeadm images so init/join needs no registry at runtime.
# containerd (apk) starts fine unprivileged; content fetch + export are plain
# file operations, so no unpacking/mounting happens inside this build step.
mkdir -p /opt/zek/images
# Minimal config for the build-time image preload only; entrypoint.sh regenerates
# the full config at runtime, so we only need the native snapshotter here.
containerd config default >/etc/containerd/config.toml
sed -i "s|^\([[:space:]]*snapshotter = \).*|\1'native'|" /etc/containerd/config.toml
containerd >/dev/null 2>&1 &
CTD_PID=$!
for i in $(seq 1 60); do [ -S /run/containerd/containerd.sock ] && break; sleep 1; done
[ -S /run/containerd/containerd.sock ]
for img in $(kubeadm config images list --kubernetes-version "${KUBERNETES_VERSION}"); do
	ctr --namespace k8s.io content fetch --platform "linux/${TARGETARCH}" "$img"
	ctr --namespace k8s.io images export --platform "linux/${TARGETARCH}" "/opt/zek/images/$(basename "${img}").tar" "$img"
done
kill "$CTD_PID"
kubeadm version -o short
EOF

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

# image for running PkgEval itself on non-Linux hosts (see bin/evaluate.jl).
# the PkgEval checkout is mounted at /PkgEval at runtime, the Julia depot
# (persisting the package cache and PkgEval's scratch spaces) lives in a volume.

FROM julia:1

# the sandboxes PkgEval creates use overlayfs, whose upper directories cannot live
# on the container's own overlayfs filesystem. sandbox working directories are
# created in TMPDIR, so point that at a volume instead.
ENV TMPDIR=/sandboxes
VOLUME /sandboxes

VOLUME /root/.julia

# the entrypoint delegates cgroup controllers, needed for sandbox resource limits
COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

WORKDIR /PkgEval

#!/bin/bash

# delegate cgroup controllers so that the sandboxes PkgEval creates can use them.
# the root cgroup cannot both contain processes and delegate controllers, so first
# move ourselves into a child cgroup.
if [ -w /sys/fs/cgroup/cgroup.subtree_control ]; then
    mkdir -p /sys/fs/cgroup/init
    while read -r pid; do
        echo "$pid" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
    done < /sys/fs/cgroup/cgroup.procs
    echo "+$(sed 's/ / +/g' /sys/fs/cgroup/cgroup.controllers)" \
        > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
fi

exec "$@"

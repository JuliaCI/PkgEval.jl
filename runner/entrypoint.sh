#!/bin/bash -ue


# prepare the user

USER=$1
USER_ID=$2
GROUP=$3
GROUP_ID=$4
shift 4

groupadd --gid $GROUP_ID $GROUP
echo "$GROUP ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

useradd --uid $USER_ID --gid $GROUP_ID --shell /bin/bash --no-create-home --no-user-group $USER
# manual home creation because it might be mounted tmpfs already
mkdir -p /home/$USER
chown $USER:$GROUP /home/$USER

# make the storage and cache writable, in case we didn't mount one
chown $USER:$GROUP /storage /cache


# prepare the depot

mkdir /home/$USER/.julia
chown $USER:$GROUP /home/$USER/.julia

mkdir -p /storage/artifacts
chown $USER:$GROUP /storage/artifacts
ln -s /storage/artifacts /home/$USER/.julia/artifacts

mkdir -p /cache/registries
chown $USER:$GROUP /cache/registries
ln -s /cache/registries /home/$USER/.julia/registries


# run the command

# discover libraries (which may be mounted at run time, e.g., libcuda by the Docker runtime)
ldconfig

cd /home/$USER
sudo --user $USER --set-home \
    CI=true PKGEVAL=true JULIA_PKGEVAL=true \
    JULIA_PKG_PRECOMPILE_AUTO=0 \
    PYTHON="" R_HOME="*" \
    -- "$@"

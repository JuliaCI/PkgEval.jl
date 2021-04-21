# Root filesystems

Scripts to generate root filesystems for PkgEval containers. These should be minimal, as
packages are generally expected to install the dependencies they need themselves, using
artifacts.

## Uploading

The filesystem tarballs are currently attached to releases of the PkgEval.jl package itself.

## Recording

```julia
using ArtifactUtils

add_artifact!("Artifacts.toml", "debian",
              "https://github.com/JuliaCI/PkgEval.jl/releases...";
              force=true, lazy=true)
```

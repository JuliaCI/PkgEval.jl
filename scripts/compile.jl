include("common.jl")

config = eval(Meta.parse(ARGS[1]))
pkg = eval(Meta.parse(ARGS[2]))
sysimage_path = ARGS[3]

println("Package compilation of $(pkg.name) started at ", now(UTC))

println()
using InteractiveUtils
versioninfo()


print("\n\n", '#'^80, "\n# Installation\n#\n\n")
t0 = cpu_time()

is_stdlib = any(Pkg.Types.stdlibs()) do (uuid,stdlib)
    name = isa(stdlib, String) ? stdlib : first(stdlib)
    name == pkg.name
end
is_stdlib && error("Packages that are standard libraries cannot be compiled again.")

println("Installing PackageCompiler...")
project = Base.active_project()
Pkg.activate(; temp=true)
Pkg.add(name="PackageCompiler", uuid="9b87118b-4619-50d2-8e1e-99f35a4d4d9d")
using PackageCompiler
Pkg.activate(project)

println("\nInstalling $(pkg.name)...")

Pkg.add(convert(Pkg.Types.PackageSpec, pkg))

println("\nCompleted after $(elapsed(t0))")


print("\n\n", '#'^80, "\n# Compilation\n#\n\n")
t1 = cpu_time()

create_sysimage([pkg.name]; sysimage_path)
println("\nCompleted after $(elapsed(t1))")

s = stat(sysimage_path).size
println("Generated system image is ", Base.format_bytes(s))

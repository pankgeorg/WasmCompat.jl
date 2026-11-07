# Git fixtures of the S-git scenario, built
# afresh inside the run dir: <rundir>/git/Foo, a package repository (main with tag v0.1.0, an
# executable script, a symlink and a subdirectory package Bar; branch dev), and <rundir>/git/Reg,
# a git registry with Foo 0.1.0 whose repo is <rundir>/git/Foo. Authors and dates are fixed, so
# Foo's commits and trees are the same in every run (Reg's differ: it records the path).

module GitFixture

const GIT_ENV = ("GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t",
                 "GIT_COMMITTER_EMAIL" => "t@t", "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z",
                 "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z", "GIT_CONFIG_NOSYSTEM" => "1")
const FOO_UUID = "7876af07-990d-54b4-ab0e-23690620f79a"
const BAR_UUID = "3fc5ad6e-8a5f-4ce1-9c6c-41c1c0d4a7b2"
const REG_UUID = "c0a2e2a8-7f4e-4a3d-9a59-0f5b2e3e6f11"

# (never an empty or relative directory: `git -C ""` would run in the caller's cwd; HOME and the
# discovery ceiling are the fixture root)
function git(root, dir, args...)
    isabspath(dir) || error("git fixture: not an absolute directory: $(repr(dir))")
    run(addenv(Cmd(["git", "-C", dir, args...]), GIT_ENV..., "HOME" => root, "GIT_CEILING_DIRECTORIES" => root))
end
git_read(root, dir, args...) =
    chomp(read(addenv(Cmd(["git", "-C", dir, args...]), GIT_ENV..., "HOME" => root, "GIT_CEILING_DIRECTORIES" => root), String))

function make(root::AbstractString)
    root = abspath(root)
    foo, reg = joinpath(root, "git", "Foo"), joinpath(root, "git", "Reg")
    mkpath(joinpath(foo, "src"))
    write(joinpath(foo, "Project.toml"), "name = \"Foo\"\nuuid = \"$FOO_UUID\"\nversion = \"0.1.0\"\n")
    write(joinpath(foo, "src", "Foo.jl"), "module Foo\nf() = 1\nend\n")
    mkpath(joinpath(foo, "bin"))
    write(joinpath(foo, "bin", "run.sh"), "#!/bin/sh\necho foo\n")
    chmod(joinpath(foo, "bin", "run.sh"), 0o755)
    symlink("src/Foo.jl", joinpath(foo, "link.jl"))
    mkpath(joinpath(foo, "sub", "Bar", "src"))
    write(joinpath(foo, "sub", "Bar", "Project.toml"), "name = \"Bar\"\nuuid = \"$BAR_UUID\"\nversion = \"0.2.0\"\n")
    write(joinpath(foo, "sub", "Bar", "src", "Bar.jl"), "module Bar\nend\n")
    git(root, foo, "init", "-q", "-b", "main")
    git(root, foo, "add", "-A")
    git(root, foo, "commit", "-qm", "one")
    git(root, foo, "tag", "v0.1.0")
    git(root, foo, "checkout", "-q", "-b", "dev")
    write(joinpath(foo, "src", "Foo.jl"), "module Foo\nf() = 2\nend\n")
    git(root, foo, "commit", "-qam", "two")
    git(root, foo, "checkout", "-q", "main")
    mkpath(joinpath(reg, "F", "Foo"))
    write(joinpath(reg, "Registry.toml"), """
        name = "Reg"
        uuid = "$REG_UUID"
        repo = "$reg"

        [packages]
        $FOO_UUID = { name = "Foo", path = "F/Foo" }
        """)
    write(joinpath(reg, "F", "Foo", "Package.toml"), "name = \"Foo\"\nuuid = \"$FOO_UUID\"\nrepo = \"$foo\"\n")
    write(joinpath(reg, "F", "Foo", "Versions.toml"),
          "[\"0.1.0\"]\ngit-tree-sha1 = \"$(git_read(root, foo, "rev-parse", "v0.1.0^{tree}"))\"\n")
    git(root, reg, "init", "-q", "-b", "main")
    git(root, reg, "add", "-A")
    git(root, reg, "commit", "-qm", "registry")
    return nothing
end

end # module

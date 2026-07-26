rebar3-cmake-plugin
====================

A rebar3 plugin for building C code with CMake

Build
-----

  $ rebar3 compile

Use
---

Add the plugin to your rebar config:

```erlang
{plugins, [
  {cmake, {git, "git://github.com/la7dja/rebar3-cmake-plugin.git", {branch, "master"}}}
]}.
```

Configure cmake options (all values below are defaults, except 'variables'):

```erlang
{cmake_opts,
 [{c_src, "c_src"},
  {c_build, "c_src"},
  {cmake_cmd, "cmake"},
  {make_cmd, "make"},
  {compile_target, ""},
  {clean_target, "clean"},
  {variables, [{"CMAKE_BUILD_TYPE", "Debug"}]}
]}.
```

The `c_src` and `c_build` option values are relative to the app's location.

### Incremental build (skip when sources are unchanged)

Because rebar3's `provider_hooks` always fire on `compile`, the plugin would
otherwise re-run CMake configure + build (~2s) even when nothing in `c_src` or
`CMakeLists.txt` changed. Configure an `artifact` to enable a staleness gate
that skips the whole build when every monitored input is no newer than the
artifact:

```erlang
{cmake_opts,
 [...,
  %% Path to the build artifact, relative to the app dir.
  %% When set and present, the build is skipped if all watch_dirs inputs
  %% have mtime <= the artifact's mtime. Unset => always build (backward compatible).
  {artifact, "priv/kcp_nif.so"},
  %% Inputs monitored for changes. Directories are scanned recursively,
  %% files are taken as-is. Defaults to ["CMakeLists.txt", "c_src"].
  {watch_dirs, ["CMakeLists.txt", "c_src"]}
]}.
```

The check is conservative: a missing artifact, an unset `artifact`, or any input
newer than the artifact always triggers a rebuild. Only enabling `artifact`
opts in; `watch_dirs` may be omitted to use the default.

#### Per-platform artifact

NIF/shared-library artifacts usually differ by OS (`.dll` / `.so` / `.dylib`).
Instead of a flat path, `artifact` may be a proplist keyed by platform. The
plugin selects the entry matching the current OS:

```erlang
{cmake_opts,
 [...,
  {artifact, [
    {win32,  "priv/kcp_nif.dll"},
    {linux,  "priv/kcp_nif.so"},
    {darwin, "priv/kcp_nif.dylib"},
    %% Optional: used when none of the above match the current OS.
    {default, "priv/kcp_nif.so"}
  ]}
]}.
```

Recognized keys: `win32`, `linux`, `darwin`, and the optional `default`.
If the proplist form is used and neither the current platform nor `default` is
present, `artifact` is treated as unset (always build). The flat-string form
remains supported and unchanged.

Add a hook to automatically build C files and clean them afterwards:

```erlang
{provider_hooks, [
  {pre, [
    {compile, {cmake, compile}},
    {clean, {cmake, clean}}
  ]}
]}.
```

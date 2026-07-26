-module(cmake_prv_compile).

-export([init/1, do/1, format_error/1]).

-define(NAMESPACE, cmake).
-define(PROVIDER, compile).
-define(DEPS, []).

-define(DEFAULT_SRC_DIR, "c_src").
-define(DEFAULT_BUILD_DIR, "_build/cmake").
%% 默认纳入变更检测的路径（相对 app dir）。
-define(DEFAULT_WATCH_DIRS, ["CMakeLists.txt", "c_src"]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
  Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {example, "rebar3 cmake compile"}, % How to use the plugin
            {opts, []},                   % list of options understood by the plugin
            {short_desc, "Build CMake project"},
            {desc, ""},
            {namespace, ?NAMESPACE}
    ]),
  {ok, rebar_state:add_provider(State, Provider)}.


-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
  Apps = case rebar_state:current_app(State) of
      undefined ->
        rebar_state:project_apps(State);
      AppInfo ->
        [AppInfo]
    end,
  lists:foreach(fun(App) -> compile(App, State) end, Apps),
  {ok, State}.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).


%% ===================================================================
%% Internal functions
%% ===================================================================
compile(AppInfo, _State) ->
  AppDir = rebar_app_info:dir(AppInfo),
  AppName = rebar_app_info:name(AppInfo),

  Opts = rebar_app_info:opts(AppInfo),
  CMakeOpts = case dict:find(cmake_opts, Opts) of
      {ok, CMakeOpts1} -> CMakeOpts1;
      error -> []
    end,

  %% ---- 变更检测：无改动且产物存在时整段跳过 ----
  case is_up_to_date(AppDir, CMakeOpts) of
    true ->
      rebar_api:info("CMake (~ts): sources unchanged, skipping build", [AppName]),
      ok;
    false ->
      run_cmake_build(AppDir, CMakeOpts)
  end.

%% 判断是否可跳过整段编译。
%% 条件：artifact 已配置 且 存在 且 所有受监控输入 mtime <= artifact mtime。
%% 未配置 artifact 时返回 false（保守，走原流程），保证向后兼容。
-spec is_up_to_date(file:filename(), proplists:proplist()) -> boolean().
is_up_to_date(AppDir, CMakeOpts) ->
  case artifact_path(AppDir, CMakeOpts) of
    undefined ->
      false;
    Artifact ->
      case filelib:last_modified(Artifact) of
        0 ->
          false;  %% 产物不存在
        ArtifactMtime ->
          WatchDirs = proplists:get_value(watch_dirs, CMakeOpts, ?DEFAULT_WATCH_DIRS),
          Inputs = collect_input_mtimes(AppDir, WatchDirs),
          NewestInput = lists:max([0 | Inputs]),
          NewestInput =< ArtifactMtime
      end
  end.

-spec artifact_path(file:filename(), proplists:proplist()) -> file:filename() | undefined.
artifact_path(AppDir, CMakeOpts) ->
  case resolve_artifact(proplists:get_value(artifact, CMakeOpts)) of
    undefined -> undefined;
    Path -> filename:join([AppDir, Path])
  end.

%% 解析 artifact 取值：支持三种形态
%%   undefined        -> 未配置
%%   字符串           -> 平铺路径（向后兼容）
%%   [{Os, Path}...]  -> 按平台配置的 proplist，依当前 OS 选取
-spec resolve_artifact(undefined | string() | proplists:proplist()) -> string() | undefined.
resolve_artifact(undefined) -> undefined;
resolve_artifact(Path) when is_list(Path) ->
  case io_lib:printable_list(Path) of
    true  -> Path;                       %% 平铺路径
    false -> resolve_artifact_list(Path) %% 按平台配置的 proplist
  end.

%% 在按平台配置的 proplist 中选取当前平台的产物路径。
%% 命中当前平台则用之，否则回退到可选的 {default, Path}；都没有则返回 undefined。
-spec resolve_artifact_list(proplists:proplist()) -> string() | undefined.
resolve_artifact_list(List) ->
  case proplists:get_value(current_platform(), List) of
    undefined -> proplists:get_value(default, List);
    Path      -> Path
  end.

%% 将 os:type() 映射为平台原子，命名与 os:type() 一致。
%% win32/linux/darwin 之外的系统返回 undefined，使 staleness gate 退化为始终构建（保守，向后兼容）。
-spec current_platform() -> win32 | linux | darwin | undefined.
current_platform() ->
  case os:type() of
    {win32, _}     -> win32;
    {unix, linux}  -> linux;
    {unix, darwin} -> darwin;
    _              -> undefined
  end.

%% 递归收集 watch_dirs 下所有普通文件的 mtime。
%% 目录项递归展开；单文件项（如 CMakeLists.txt）直接取 mtime。
-spec collect_input_mtimes(file:filename(), [string()]) -> [calendar:datetime()].
collect_input_mtimes(AppDir, WatchDirs) ->
  Files = lists:flatmap(
    fun(Entry) ->
        Abs = filename:join([AppDir, Entry]),
        case filelib:is_dir(Abs) of
          true  -> filelib:wildcard(filename:join([Abs, "**", "*"]));
          false -> case filelib:is_file(Abs) of true -> [Abs]; false -> [] end
        end
    end, WatchDirs),
  [filelib:last_modified(F) || F <- Files, filelib:is_regular(F)].

-spec run_cmake_build(file:filename(), proplists:proplist()) -> ok.
run_cmake_build(AppDir, CMakeOpts) ->
  SrcDir = filename:join([AppDir, proplists:get_value(c_src, CMakeOpts, ?DEFAULT_SRC_DIR)]),
  BuildDir = filename:join([AppDir, proplists:get_value(c_build, CMakeOpts, ?DEFAULT_BUILD_DIR)]),
  Variables = [[" -D", Key, "=", Value] || {Key, Value} <- proplists:get_value(variables, CMakeOpts, []),
                Key =/= "CMAKE_BUILD_TYPE"],
  CMakeCmd = proplists:get_value(cmake_cmd, CMakeOpts, "cmake"),
  MakeCmd = proplists:get_value(make_cmd, CMakeOpts, "make"),
  Target = proplists:get_value(compile_target, CMakeOpts, ""),

  case rebar_utils:sh([CMakeCmd, " -S ", SrcDir, " -B ", BuildDir, Variables], [return_on_error, use_stdout]) of
    {error, {_, CMakeError}} ->
      rebar_api:error("~ts", [unicode:characters_to_list(CMakeError)]),
      rebar_api:abort();
    {ok, CMakeOutput} ->
      rebar_api:info("Running CMake~n~ts", [unicode:characters_to_list(CMakeOutput)])
  end,

  case os:type() of
    {win32, _} ->
       BuildType = proplists:get_value("CMAKE_BUILD_TYPE", proplists:get_value(variables, CMakeOpts, []), "Debug"),
       case rebar_utils:sh([CMakeCmd, " --build ", BuildDir, " --config ", BuildType], [return_on_error, use_stdout]) of
         {error, {_, MakeError}} ->
           rebar_api:error("~ts", [unicode:characters_to_list(MakeError)]),
           rebar_api:abort();
         {ok, MakeOutput} ->
           rebar_api:info("~ts", [unicode:characters_to_list(MakeOutput)])
       end;
    _ ->
       case rebar_utils:sh([MakeCmd, " -C", BuildDir, " ", Target], [return_on_error, use_stdout]) of
         {error, {_, MakeError}} ->
           rebar_api:error("~tss", [unicode:characters_to_list(MakeError)]),
           rebar_api:abort();
         {ok, MakeOutput} ->
           rebar_api:info("~ts", [unicode:characters_to_list(MakeOutput)])
       end
  end.

-module(cmake_prv_compile).

-export([init/1, do/1, format_error/1]).

-define(NAMESPACE, cmake).
-define(PROVIDER, compile).
-define(DEPS, []).

-define(DEFAULT_SRC_DIR, "c_src").
-define(DEFAULT_BUILD_DIR, "_build/cmake").

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

  Opts = rebar_app_info:opts(AppInfo),
  CMakeOpts = case dict:find(cmake_opts, Opts) of
      {ok, CMakeOpts1} -> CMakeOpts1;
      error -> []
    end,
      
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

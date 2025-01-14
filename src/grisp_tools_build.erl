-module(grisp_tools_build).

% API
-export([run/1]).

-import(grisp_tools_util, [event/2]).
-import(grisp_tools_util, [shell/2]).
-import(grisp_tools_util, [shell/3]).

%--- API -----------------------------------------------------------------------

run(Configuration) ->
    State = mapz:deep_merge(Configuration, #{
        build => #{
            overlay => #{
                files => #{},
                patches => #{},
                drivers => #{},
                nifs => #{}
            }
        }
    }),

    grisp_tools_util:weave(State, [
        fun grisp_tools_step:config/1,
        {fun build/1, [
            {validate, [
                fun grisp_tools_step:apps/1,
                fun grisp_tools_step:version/1
            ]},
            fun grisp_tools_step:collect/1,
            fun download/1,
            {fun prepare/1, [
                fun clean/1,
                fun patch/1,
                {copy, [
                    fun files/1,
                    fun drivers/1,
                    fun nifs/1
                ]}
            ]},
            {compile, [
                fun configure/1,
                fun boot/1,
                fun install/1,
                fun post/1
            ]},
            fun tar/1
        ]}
    ]).

%--- Internal Steps ------------------------------------------------------------

build(S0) ->
    S1 = event(S0, [{platform, maps:get(platform, S0)}]),
    ToolchainRoot = mapz:deep_get([paths, toolchain], S1),
    PATH = os:getenv("PATH"),
    Env = #{
        "GRISP_TC_ROOT" => ToolchainRoot,
        "PATH" => filename:join(ToolchainRoot, "bin") ++ ":" ++ PATH
    },
    mapz:deep_merge(S1, #{shell => #{env => Env}}).

download(#{otp_version := {_,_,_,Ver}} = S0) ->
    BuildPath = mapz:deep_get([paths, build], S0),
    % FIXME: Check actual state of checkout instead of just checking for folder
    % presence!
    case filelib:is_dir(filename:join(BuildPath, ".git")) of
        false ->
            URL = grisp_tools_util:env(otp_git_url),
            Branch = ["OTP-", Ver],
            % See https://github.com/erlang/rebar3/pull/2660
            S1 = mapz:deep_put([shell, env, "GIT_TERMINAL_PROMPT"], "0", S0),
            {{ok, Output}, S2} = shell(S1,
                "git clone "
                "-b " ++ Branch ++ " "
                "--depth 1 " ++
                "--single-branch " ++
                URL ++ " " ++ BuildPath
            ),
            event(mapz:deep_put([build, download], true, S2), [{output, Output}]);
        true ->
            event(mapz:deep_put([build, download], false, S0), ['_skip'])
    end.

prepare(S0) ->
    Drivers = maps:to_list(mapz:deep_get([build, overlay, drivers], S0)),
    NIFs = maps:to_list(mapz:deep_get([build, overlay, nifs], S0)),
    DriverFiles = [#{name => filename:basename(N, ".c")} || {N, _P} <- Drivers],
    NIFFiles = [#{name => filename:basename(N, ".c")} || {N, _P} <- NIFs],

    DrvPatchLineCount = 10 + length(DriverFiles),
    NifPatchLineCount = 9 + length(NIFFiles),

    Context = #{
        erts_emulator_makefile_in => #{
            driver_lines => DrvPatchLineCount,
            nif_lines => NifPatchLineCount,
            total_lines => DrvPatchLineCount + NifPatchLineCount,
            drivers => DriverFiles,
            nifs => NIFFiles
        }
    },
    mapz:deep_put([build, context], Context, S0).

clean(#{build := #{flags := #{clean := true}}} = State0) ->
    State1 = event(State0, ['_run']),
    BuildPath = mapz:deep_get([paths, build], State1),
    grisp_tools_util:pipe(State1, [
        fun(S) -> shell_ok(S, "git reset --hard", [{cd, BuildPath}]) end,
        fun(S) -> shell_ok(S, "git clean -fXd", [{cd, BuildPath}]) end,
        fun(S) -> shell_ok(S, "git clean -fxd", [{cd, BuildPath}]) end
    ]);
clean(State0) ->
    event(State0, ['_skip']).

patch(#{build := #{overlay := #{patches := Patches}}} = S0) ->
    Sorted = lists:sort(maps:to_list(Patches)),
    lists:foldl(fun apply_patch/2, S0, Sorted).

files(State0) -> copy_files(State0, files, "").

drivers(State0) -> copy_files(State0, drivers, "").

nifs(State0) -> copy_files(State0, nifs, "").

copy_files(State0, Type, SubDir) ->
    #{
        sorted_apps := Apps,
        build := #{overlay := #{Type := FileMap}},
        paths := #{build := Root}
    } = State0,
    case maps:size(FileMap) of
        0 ->
            event(State0, ['_skip']);
        _Size ->
            Files = sort_files(Apps, FileMap),
            Target = filename:join(Root, SubDir),
            lists:foldl(fun(F, S) -> copy_file(Target, F, S) end, State0, Files)
    end.

configure(#{build := Build} = S0) ->
    #{
        download := WasDownloaded,
        flags := #{clean := DidClean, configure := ShouldConfigure}
    } = Build,
    % We must configure if we just downloaded or cleaned the repository
    case WasDownloaded orelse DidClean orelse ShouldConfigure of
        true ->
            S1 = case {WasDownloaded, DidClean, ShouldConfigure} of
                {true, _, false} -> event(S0, [{'_override', download}]);
                {_, true, false} -> event(S0, [{'_override', clean}]);
                {_, _, _} -> S0
            end,
            Opts = [{cd, mapz:deep_get([paths, build], S1)}],
            % TODO: Remove autoconf step when supporting only 23.3+ (not needed)
            S2 = build_step("./otp_build autoconf", Opts, S1),
            XCompConf = mapz:deep_get([build, config, xcomp_conf], S2),
            Command = [
                "./otp_build configure ",
                " --prefix=/",

                % Disable apps not built for target
                " --without-debugger",
                " --without-dialyzer",
                " --without-erl_interface",
                " --without-et",
                " --without-hipe",
                " --without-javac",
                " --without-jinterface",
                " --without-megaco",
                " --without-observer",
                " --without-odbc",
                " --without-os_mon",
                " --without-typer",
                " --without-wx",
                " --xcomp-conf=", XCompConf
            ],
            build_step(Command, Opts, S2);
        false ->
            event(S0, ['_skip'])
    end.

boot(State0) ->
    Opts = [{cd, mapz:deep_get([paths, build], State0)}],
    build_step("./otp_build boot -a", Opts, State0).

install(S0) ->
    BuildPath = mapz:deep_get([paths, build], S0),
    InstallPath = mapz:deep_get([paths, install], S0),

    grisp_tools_util:ensure_dir(filename:join(InstallPath, ".")),
    S1 = grisp_tools_util:pipe(S0, [
        fun(S) -> shell_ok(S, ["rm -rf ", filename:join(InstallPath, "*")], [{cd, InstallPath}]) end,
        fun(S) -> shell_ok(S, ["make install DESTDIR=", $", InstallPath, $"], [{cd, BuildPath}]) end
    ]),

    [ERTS] = filelib:wildcard(to_list(filename:join(InstallPath, "lib/erlang/erts-*"))),
    Ver = lists:last(string:split(ERTS, "-", trailing)),

    S2 = mapz:deep_merge(S1, #{shell => #{env => #{
        "OTP_ROOT" => to_list(InstallPath),
        "ERTS_VERSION" => Ver
    }}}),

    run_hooks(S2, post_install, [{cd, InstallPath}]).

post(#{build := #{hash := #{index := Index}}} = S0) ->
    PackageListing = filename:join(mapz:deep_get([paths, install], S0), "GRISP_PACKAGE_FILES"),
    ok = file:write_file(PackageListing, grisp_tools_util:build_hash_format(Index)),

    % info("Copying revision string into install dir"),
    ToolchainRoot = mapz:deep_get([paths, toolchain], S0),
    InstallPath = mapz:deep_get([paths, install], S0),
    RevSource = filename:join([ToolchainRoot, "GRISP_TOOLCHAIN_REVISION"]),
    RevDestination = filename:join(InstallPath, "GRISP_TOOLCHAIN_REVISION"),
    case file:copy(RevSource, RevDestination) of
        {ok, _} -> ok;
        _ -> error({missing_toolchain_revision, RevSource})
    end,
    S0.

tar(#{build := #{flags := #{tar := true}}} = S0) ->
    #{paths := #{package := PackagePath, install := InstallPath}} = S0,
    Name = grisp_tools_util:package_name(S0),
    Package = filename:join(PackagePath, Name),
    grisp_tools_util:ensure_dir(Package),
    shell_ok(S0, ["tar -zcf ", Package, " ."], [{cd, InstallPath}]),
    event(S0, [{file, relative(Package)}]);
tar(S0) ->
    event(S0, ['_skip']).

build_step(Command, Opts, State0) ->
    {{ok, Output}, State1} = shell(State0, Command, Opts),
    event(State1, [{output, Output}]).

%--- Internal ------------------------------------------------------------------

apply_patch({Name, Patch}, State0) ->
    Dir = mapz:deep_get([paths, build], State0),
    Context = mapz:deep_get([build, context], State0),
    grisp_tools_util:write_file(Dir, Patch, Context),
    State4 = case shell(State0, ["git apply ", Name, " --ignore-whitespace --reverse --check"],
            [{cd, Dir}, return_on_error]) of
        {{ok, _Output}, State1} ->
            event(State1, [{skip, Patch}]);
        {{error, {1, _}}, State1} ->
            State2 = event(State1, [{apply, Patch}]),
            {{ok, _}, State3} = shell(State2, "git apply --ignore-whitespace " ++ Name, [{cd, Dir}]),
            State3
    end,
    {{ok, _}, State5} = shell(State4, "rm " ++ Name, [{cd, Dir}]),
    State5.

sort_files(Apps, Files) ->
    Indices = maps:from_list(lists:zip(Apps, lists:seq(1, length(Apps)))),
    SortFiles = fun
        (#{app := A, name := N1}, #{app := A, name := N2}) ->
            N1 =< N2;
        (#{app := A1}, #{app := A2}) ->
            maps:get(A1, Indices) =< maps:get(A2, Indices)
    end,
    lists:sort(SortFiles, [F || {_, F} <- maps:to_list(Files)]).

copy_file(Root, File, State0) ->
    State1 = event(State0, [File]),
    Context = mapz:deep_get([build, context], State0),
    grisp_tools_util:write_file(Root, File, Context),
    State1.

run_hooks(S0, Type, Opts) ->
    Hooks = mapz:deep_get([build, overlay, hooks, Type], S0, []),
    case maps:size(Hooks) of
        0 ->
            S0;
        _Else ->
            S1 = event(S0, [hook, Type]),
            lists:foldl(fun({_Name, #{source := Source} = Hook}, S2) ->
                S3 = event(S2, [hook, Type, {run, Hook}]),
                shell_ok(S3, Source, Opts)
            end, S1, lists:sort(maps:to_list(Hooks)))
    end.

shell_ok(State0, Hook, Opts) ->
    {{ok, _Output}, State1} = shell(State0, Hook, Opts),
    State1.

to_list(Binary) when is_binary(Binary) -> binary_to_list(Binary);
to_list(List) when is_list(List) -> List.

relative(Path) ->
    {ok, CWD} = file:get_cwd(),
    string:trim(string:prefix(Path, CWD), leading, "/").

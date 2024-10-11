%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(esockd_acceptor).

-behaviour(gen_statem).

-include("esockd.hrl").

-export([ start_link/7
        , set_conn_limiter/2
        ]).

%% state callbacks
-export([ accepting/3
        , suspending/3
        ]).

%% gen_statem Callbacks
-export([ init/1
        , callback_mode/0
        , terminate/3
        , code_change/4
        ]).

-record(state, {
          proto        :: atom(),
          listen_on    :: esockd:listen_on(),
          lsock        :: inet:socket(),
          sockmod      :: module(),
          sockname     :: {inet:ip_address(), inet:port_number()},
          tune_fun     :: esockd:sock_fun(),
          upgrade_funs :: [esockd:sock_fun()],
          conn_limiter :: undefined | esockd_limiter:bucket_name(),
          conn_sup     :: pid(),
          accept_ref   :: term()
        }).

%% enotconn happens when client sends TCP reset instead of FIN
%% einval may happen for connections from haproxy check
-define(IS_QUIET(R), (R =:= enotconn orelse R =:= einval orelse R =:= closed)).

%% @doc Start an acceptor
-spec(start_link(atom(), esockd:listen_on(), pid(),
                 esockd:sock_fun(), [esockd:sock_fun()],
                 esockd_limiter:bucket_name(), inet:socket())
      -> {ok, pid()} | {error, term()}).
start_link(Proto, ListenOn, ConnSup,
           TuneFun, UpgradeFuns, Limiter, LSock) ->
    gen_statem:start_link(?MODULE, [Proto, ListenOn, ConnSup,
                                    TuneFun, UpgradeFuns, Limiter, LSock], []).

-spec(set_conn_limiter(pid(), esockd_limiter:bucket_name()) -> ok).
set_conn_limiter(Acceptor, Limiter) ->
    gen_statem:call(Acceptor, {set_conn_limiter, Limiter}, 5000).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Proto, ListenOn, ConnSup, TuneFun, UpgradeFuns, Limiter, LSock]) ->
    _ = rand:seed(exsplus, erlang:timestamp()),
    {ok, Sockname} = inet:sockname(LSock),
    {ok, SockMod} = inet_db:lookup_socket(LSock),
    {ok, accepting, #state{proto         = Proto,
                           listen_on     = ListenOn,
                           lsock         = LSock,
                           sockmod       = SockMod,
                           sockname      = Sockname,
                           tune_fun      = TuneFun,
                           upgrade_funs  = UpgradeFuns,
                           conn_limiter  = Limiter,
                           conn_sup      = ConnSup},
     {next_event, internal, accept}}.

callback_mode() -> state_functions.

do_async_accept(StateName, State = #state{lsock = LSock}) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} ->
            {keep_state, State#state{accept_ref = Ref}};
        {error, Reason} when Reason =:= emfile;
                             Reason =:= enfile ->
            case StateName of
                accepting ->
                    to_suspending(State, 10_000);
                _ ->
                    {keep_state, State}
            end;
        {error, closed} ->
            {stop, normal, State};
        {error, Reason} ->
            {stop, Reason, State}
    end.

accepting(internal, accept, State) ->
    do_async_accept(accepting, State);
accepting({call, From}, {set_conn_limiter, Limiter}, State) ->
    {keep_state, State#state{conn_limiter = Limiter}, {reply, From, ok}};

accepting(info, {inet_async, LSock, Ref, {ok, Sock}},
          State = #state{proto        = Proto,
                         listen_on    = ListenOn,
                         lsock        = LSock,
                         sockmod      = SockMod,
                         sockname     = Sockname,
                         tune_fun     = TuneFun,
                         upgrade_funs = UpgradeFuns,
                         conn_sup     = ConnSup,
                         accept_ref   = Ref}) ->
    %% make it look like gen_tcp:accept
    inet_db:register_socket(Sock, SockMod),

    %% Inc accepted stats.
    esockd_server:inc_stats({Proto, ListenOn}, accepted, 1),

    Result = case eval_tune_socket_fun(TuneFun, Sock) of
        {ok, _} ->
            case esockd_connection_sup:start_connection(ConnSup, Sock, UpgradeFuns) of
                {ok, _Pid} ->
                    consume_limiter;
                {error, Reason} when ?IS_QUIET(Reason) ->
                    {error, Reason};
                {error, Reason} ->
                    error_logger:error_msg("Failed to start connection on ~s: ~p",
                                           [esockd:format(Sockname), Reason]),
                    {error, Reason}
            end;
        {error, Reason} when ?IS_QUIET(Reason) ->
            {error, Reason};
        {error, Reason} ->
            error_logger:error_msg("Tune buffer failed on ~s: ~s",
                                   [esockd:format(Sockname), Reason]),
            {error, Reason}
    end,
    case Result of
        {error, _} ->
            close(Sock);
        _ ->
            ok
    end,
    rate_limit(State, Result);
accepting(info, {inet_async, LSock, Ref, {error, closed}},
          State = #state{lsock = LSock, accept_ref = Ref}) ->
    {stop, normal, State#state{accept_ref = false}};

%% {error, econnaborted} -> accept
%% {error, esslaccept}   -> accept
accepting(info, {inet_async, LSock, Ref, {error, Reason}},
          State = #state{lsock = LSock, accept_ref = Ref})
    when Reason =:= econnaborted; Reason =:= esslaccept ->
    {keep_state, State#state{accept_ref = false}, {next_event, internal, accept}};

%% emfile: The per-process limit of open file descriptors has been reached.
%% enfile: The system limit on the total number of open files has been reached.
accepting(info, {inet_async, LSock, Ref, {error, Reason}},
          State = #state{lsock = LSock, sockname = Sockname, accept_ref = Ref})
    when Reason =:= emfile; Reason =:= enfile ->
    error_logger:error_msg("Accept error on ~s: ~s",
                           [esockd:format(Sockname), esockd_utils:explain_posix(Reason)]),
    to_suspending(State#state{accept_ref = false}, 10_000);
accepting(info, {inet_async, LSock, Ref, {error, Reason}},
          State = #state{lsock = LSock, accept_ref = Ref}) ->
    {stop, Reason, State#state{accept_ref = false}}.

suspending({call, From}, {set_conn_limiter, Limiter}, State) ->
    {keep_state, State#state{conn_limiter = Limiter}, {reply, From, ok}};
suspending(info, start_accepting, State) ->
    Actions =
        case State of
            #state{accept_ref = false} ->
                {next_event, internal, accept};
            _ ->
                []
        end,
    {next_state, accepting, State, Actions};
suspending(internal, accept_and_close, State) ->
    do_async_accept(suspending, State);
suspending(info, {inet_async, _LSock, Ref, {ok, Sock}},
           #state{proto        = Proto,
                  listen_on    = ListenOn,
                  sockmod      = SockMod,
                  accept_ref   = Ref} = State) ->
    %% make it look like gen_tcp:accept
    inet_db:register_socket(Sock, SockMod),

    %% Inc limited stats.
    %% catch for hot-upgrade, the metrics is not initialized yet
    _ = catch esockd_server:inc_stats({Proto, ListenOn}, limited, 1),
    close(Sock),
    {keep_state, State#state{accept_ref = false},
     {next_event, internal, accept_and_close}};
suspending(info, {inet_async, LSock, Ref, {error, closed}},
          State = #state{lsock = LSock, accept_ref = Ref}) ->
    {stop, normal, State#state{accept_ref = false}};
suspending(info, {inet_async, LSock, Ref, {error, Reason}},
          #state{lsock = LSock, accept_ref = Ref} = State)
    when Reason =:= econnaborted; Reason =:= esslaccept ->
    {keep_state, State#state{accept_ref = false}, {next_event, internal, accept_and_close}};
suspending(info, {inet_async, LSock, Ref, {error, Reason}},
          State = #state{lsock = LSock, sockname = Sockname, accept_ref = Ref})
    when Reason =:= emfile; Reason =:= enfile ->
    error_logger:error_msg("Accept error on ~s: ~s",
                           [esockd:format(Sockname), esockd_utils:explain_posix(Reason)]),
    {keep_state, State#state{accept_ref = false}};
suspending(info, {inet_async, LSock, Ref, {error, Reason}},
          State = #state{lsock = LSock, accept_ref = Ref}) ->
    {stop, Reason, State#state{accept_ref = false}}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

to_suspending(State, Pause) ->
    _ = erlang:send_after(Pause, self(), start_accepting),
    {next_state, suspending, State, {next_event, internal, accept_and_close}}.

close(Sock) -> catch port_close(Sock).

rate_limit(State = #state{conn_limiter = Limiter}, consume_limiter) ->
    case esockd_limiter:consume(Limiter, 1) of
        {I, Pause} when I =< 0 ->
            to_suspending(State, Pause);
        _ ->
            {keep_state, State, {next_event, internal, accept}}
    end;
rate_limit(State, _NotAccepted) ->
    %% Socket closed or error by the time when accepting it
    {keep_state, State, {next_event, internal, accept}}.

eval_tune_socket_fun({Fun, Args1}, Sock) ->
    apply(Fun, [Sock|Args1]).

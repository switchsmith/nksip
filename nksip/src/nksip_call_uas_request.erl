%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private Call UAS Management: Request Processing
-module(nksip_call_uas_request).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/3, reply/4]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec request(nksip:request(), nksip_call_uas:id(), nksip_call:call()) ->
    nksip_call:call().

request(Req, TransId, Call) ->
    #sipmsg{id=MsgId, method=Method, ruri=RUri, transport=Transp, to_tag=ToTag} = Req,
    #call{trans=Trans, next=Id, msgs=Msgs} = Call,
    ?call_debug("UAS ~p started for ~p (~s)", [Id, Method, MsgId], Call),
    LoopId = loop_id(Req),
    UAS = #trans{
        id = Id,
        class = uas,
        status = authorize,
        opts = [],
        start = nksip_lib:timestamp(),
        from = undefined,
        trans_id = TransId, 
        request = Req,
        method = Method,
        ruri = RUri,
        proto = Transp#transport.proto,
        stateless = true,
        response = undefined,
        code = 0,
        loop_id = LoopId
    },
     UAS1 = case Method of
        'INVITE' -> nksip_call_lib:timeout_timer(timer_c, UAS, Call);
        'ACK' -> UAS;
        _ -> nksip_call_lib:timeout_timer(noinvite, UAS, Call)
    end,
    Msg = {MsgId, Id, nksip_dialog:id(Req)},
    Call1 = Call#call{trans=[UAS1|Trans], next=Id+1, msgs=[Msg|Msgs]},
    case ToTag=:=(<<>>) andalso lists:keymember(LoopId, #trans.loop_id, Trans) of
        true -> reply(loop_detected, UAS1, Call1);
        false -> send_100(UAS1, Call1)
    end.



%% @private Called by {@link nksip_call_router} when there is a SipApp response available
-spec reply(atom(), nksip_call_uas:id(), nksip:sipreply(), nksip_call:call()) ->
    nksip_call:call().

reply(Fun, Id, Reply, #call{trans=Trans}=Call) ->
    case lists:keyfind(Id, #trans.id, Trans) of
        #trans{class=uas}=UAS when Reply=:=async ->
            UAS1 = nksip_call_lib:cancel_timers([app], UAS),
            update(UAS1, Call);
        #trans{class=uas, app_timer={Fun, _}, request=Req}=UAS ->
            UAS1 = nksip_call_lib:cancel_timers([app], UAS),
            Call1 = update(UAS1, Call),
            case Fun of
                authorize -> 
                    authorize_reply(Reply, UAS1, Call1);
                route -> 
                    route_reply(Reply, UAS1, Call1);
                ack ->
                    Call1;
                _ when not is_record(Req, sipmsg) ->
                    Call1;
                _ when Fun=:=invite; Fun=:=reinvite; Fun=:=bye; 
                       Fun=:=options; Fun=:=register ->
                    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
                    {Resp, Opts} = nksip_reply:reply(Req, Reply, AppOpts),
                    {Resp1, Opts1} = case Resp#sipmsg.response >= 200 of
                        true -> 
                            {Resp, Opts};
                        false -> 
                            Reply1 = {internal_error, <<"Invalid SipApp reply">>},
                            nksip_reply:reply(Req, Reply1)
                    end,
                    reply({Resp1, Opts1}, UAS1, Call1)
            end;
        _ ->
            ?call_debug("Unknown UAS ~p received SipApp ~p reply",
                        [Id, Fun], Call),
            Call
    end.


%% @private 
-spec send_100(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

send_100(UAS, #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}}=Call) ->
    #trans{id=Id, method=Method, request=Req} = UAS,
    case Method=:='INVITE' andalso (not lists:member(no_100, AppOpts)) of 
        true ->
            case nksip_transport_uas:send_user_response(Req, 100, GlobalId, AppOpts) of
                {ok, _} -> 
                    check_cancel(UAS, Call);
                error ->
                    ?call_notice("UAS ~p ~p could not send '100' response", 
                                 [Id, Method], Call),
                    reply(service_unavailable, UAS, Call)
            end;
        false -> 
            check_cancel(UAS, Call)
    end.
        

%% @private
-spec check_cancel(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_cancel(#trans{id=Id}=UAS, Call) ->
    case is_cancel(UAS, Call) of
        {true, #trans{id=InvId, status=Status}=InvUAS} ->
            ?call_debug("UAS ~p matched 'CANCEL' as ~p (~p)", 
                        [Id, InvId, Status], Call),
            if
                Status=:=authorize; Status=:=route; Status=:=invite_proceeding ->
                    Call1 = reply(ok, UAS, Call),
                    nksip_call_uas:terminate_request(InvUAS, Call1);
                true ->
                    reply(no_transaction, UAS, Call)
            end;
        false ->
            % Only for case of stateless proxy
            authorize_launch(UAS, Call)
    end.


%% @private Finds the INVITE transaction belonging to a CANCEL transaction
-spec is_cancel(nksip_call:trans(), nksip_call:call()) ->
    {true, nksip_call:trans()} | false.

is_cancel(#trans{method='CANCEL', request=CancelReq}, #call{trans=Trans}=Call) -> 
    ReqTransId = nksip_call_uas:transaction_id(CancelReq#sipmsg{method='INVITE'}),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{id=Id, class=uas, request=#sipmsg{}=InvReq} = InvUAS ->
            #sipmsg{transport=#transport{remote_ip=CancelIp, remote_port=CancelPort}} =
                CancelReq,
            #sipmsg{transport=#transport{remote_ip=InvIp, remote_port=InvPort}} =
                InvReq,
            if
                CancelIp=:=InvIp, CancelPort=:=InvPort ->
                    {true, InvUAS};
                true ->
                    ?call_notice("UAS ~p rejecting CANCEL because it came from ~p:~p, "
                                 "INVITE came from ~p:~p", 
                                 [Id, CancelIp, CancelPort, InvIp, InvPort], Call),
                    false
            end;
        _ ->
            ?call_debug("received unknown CANCEL", [], Call),
            false
    end;

is_cancel(_, _) ->
    false.


%% @private
-spec authorize_launch(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

authorize_launch(UAS, Call) ->
    #call{opts=#call_opts{app_module=Module}} = Call,
    case 
        erlang:function_exported(Module, authorize, 3) orelse
        erlang:function_exported(Module, authorize, 4)
    of
        true ->
            Auth = authorize_data(UAS, Call),
            case app_call(authorize, [Auth], UAS, Call) of
                {reply, Reply} -> authorize_reply(Reply, UAS, Call);
                #call{} = Call1 -> Call1
            end;
        false ->
            authorize_reply(ok, UAS, Call)
    end.


%% @private
-spec authorize_data(nksip_call:trans(), nksip_call:call()) ->
    list().

authorize_data(#trans{id=Id,request=Req}, Call) ->
    #call{app_id=AppId, opts=#call_opts{app_module=Module, app_opts=Opts}} = Call,
    IsDialog = case nksip_call_lib:check_auth(Req, Call) of
        true -> dialog;
        false -> []
    end,
    IsRegistered = case nksip_registrar:is_registered(Req) of
        true -> register;
        false -> []
    end,
    PassFun = fun(User, Realm) ->
        Args = [User, Realm],
        case nksip_sipapp_srv:sipapp_call(AppId, Module, get_user_pass, Args, Args) of
            {reply, Reply} -> 
                ok;
            error -> 
                Reply = false;
            not_exported ->
                {reply, Reply, _} = nksip_sipapp:get_user_pass(User, Realm, Opts)
        end,
        ?call_debug("UAS ~p calling get_user_pass(~p, ~p): ~p", 
                    [Id, User, Realm, Reply], Call),
        Reply
    end,
    IsDigest = nksip_auth:get_authentication(Req, PassFun),
    lists:flatten([IsDialog, IsRegistered, IsDigest]).


%% @private
-spec authorize_reply(term(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

authorize_reply(Reply, #trans{status=authorize}=UAS, Call) ->
    #trans{id=Id, method=Method, request=_Req} = UAS,
    ?call_debug("UAS ~p ~p authorize reply: ~p", [Id, Method, Reply], Call),
    case Reply of
        ok -> route_launch(UAS, Call);
        true -> route_launch(UAS, Call);
        false -> reply(forbidden, UAS, Call);
        authenticate -> reply(authenticate, UAS, Call);
        {authenticate, Realm} -> reply({authenticate, Realm}, UAS, Call);
        proxy_authenticate -> reply(proxy_authenticate, UAS, Call);
        {proxy_authenticate, Realm} -> reply({proxy_authenticate, Realm}, UAS, Call);
        Other -> reply(Other, UAS, Call)
    end;

% Request has been already answered (i.e. cancelled)
authorize_reply(_Reply, UAS, Call) ->
    update(UAS, Call).



%% @private
-spec route_launch(nksip_call:trans(), nksip_call:call()) -> 
    nksip_call:call().

route_launch(#trans{ruri=RUri}=UAS, Call) ->
    UAS1 = UAS#trans{status=route},
    Call1 = update(UAS1, Call),
    #uri{scheme=Scheme, user=User, domain=Domain} = RUri,
    case app_call(route, [Scheme, User, Domain], UAS1, Call1) of
        {reply, Reply} -> route_reply(Reply, UAS1, Call1);
        not_exported -> route_reply(process, UAS1, Call1);
        #call{} = Call2 -> Call2
    end.
    

%% @private
-spec route_reply(term(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

route_reply(Reply, #trans{status=route}=UAS, Call) ->
    #trans{id=Id, method=Method, ruri=RUri, request=Req} = UAS,
    ?call_debug("UAS ~p ~p route reply: ~p", [Id, Method, Reply], Call),
    Route = case Reply of
        {response, Resp} -> {response, Resp, []};
        {response, Resp, Opts} -> {response, Resp, Opts};
        process -> {process, []};
        {process, Opts} -> {process, Opts};
        proxy -> {proxy, RUri, []};
        {proxy, Uris} -> {proxy, Uris, []}; 
        {proxy, ruri, Opts} -> {proxy, RUri, Opts};
        {proxy, Uris, Opts} -> {proxy, Uris, Opts};
        strict_proxy -> {strict_proxy, []};
        {strict_proxy, Opts} -> {strict_proxy, Opts};
        Resp -> {response, Resp, [stateless]}
    end,
    Status = case Method of
        'INVITE' -> invite_proceeding;
        'ACK' -> ack;
        _ -> trying
    end,
    UAS1 = UAS#trans{status=Status},
    Call1 = update(UAS1, Call),
    case Route of
        {process, _} when Method=/='CANCEL', Method=/='ACK' ->
            case nksip_sipmsg:header(Req, <<"Require">>, tokens) of
                [] -> 
                    do_route(Route, UAS1, Call1);
                Requires -> 
                    RequiresTxt = nksip_lib:bjoin([T || {T, _} <- Requires]),
                    reply({bad_extension,  RequiresTxt}, UAS1, Call1)
            end;
        _ ->
            do_route(Route, UAS1, Call1)
    end;

% Request has been already answered
route_reply(_Reply, UAS, Call) ->
    update(UAS, Call).


%% @private
-spec do_route({response, nksip:sipreply(), nksip_lib:proplist()} |
               {process, nksip_lib:proplist()} |
               {proxy, nksip:uri_set(), nksip_lib:proplist()} |
               {strict_proxy, nksip_lib:proplist()}, 
               nksip_call:trans(), nksip_call:call()) -> 
    nksip_call:call().

do_route({response, Reply, Opts}, #trans{method=Method}=UAS, Call) ->
    Stateless = case Method of
        'INVITE' -> false;
        _ -> lists:member(stateless, Opts)
    end,
    UAS1 = UAS#trans{stateless=Stateless},
    reply(Reply, UAS1, update(UAS1, Call));

%% CANCEL should have been processed already
do_route({process, _Opts}, #trans{method='CANCEL'}=UAS, Call) ->
    reply(no_transaction, UAS, Call);

do_route({process, Opts}, #trans{request=Req, method=Method}=UAS, Call) ->
    Stateless = case Method of
        'INVITE' -> false;
        _ -> lists:member(stateless, Opts)
    end,
    UAS1 = UAS#trans{stateless=Stateless},
    UAS2 = case nksip_lib:get_value(headers, Opts) of
        Headers1 when is_list(Headers1) -> 
            #sipmsg{headers=Headers} = Req,
            Req1 = Req#sipmsg{headers=Headers1++Headers},
            UAS1#trans{request=Req1};
        _ -> 
            UAS1
    end,
    process(UAS2, update(UAS2, Call));

% We want to proxy the request
do_route({proxy, UriList, ProxyOpts}, UAS, Call) ->
    #trans{id=Id, opts=Opts, method=Method} = UAS,
    case nksip_call_proxy:route(UAS, UriList, ProxyOpts, Call) of
        stateless_proxy ->
            UAS1 = UAS#trans{status=finished},
            update(UAS1, Call);
        {fork, _, _} when Method=:='CANCEL' ->
            reply(no_transaction, UAS, Call);
        {fork, UAS1, UriSet} ->
            % ProxyOpts may include record_route
            % TODO 16.6.4: If ruri or top route has sips, and not received with 
            % tls, must record_route. If received with tls, and no sips in ruri
            % or top route, must record_route also
            UAS2 = UAS1#trans{opts=[no_dialog|Opts], stateless=false, from={fork, Id}},
            UAS3 = case Method of
                'ACK' -> UAS2#trans{status=finished};
                _ -> UAS2
            end,
            nksip_call_fork:start(UAS3, UriSet, ProxyOpts, update(UAS3, Call));
        {reply, SipReply} ->
            reply(SipReply, UAS, Call)
    end;


% Strict routing is here only to simulate an old SIP router and 
% test the strict routing capabilities of NkSIP 
do_route({strict_proxy, Opts}, #trans{request=Req}=UAS, Call) ->
    case Req#sipmsg.routes of
       [Next|_] ->
            ?call_info("strict routing to ~p", [Next], Call),
            do_route({proxy, Next, [stateless|Opts]}, UAS, Call);
        _ ->
            reply({internal_error, <<"Invalid Srict Routing">>}, UAS, Call)
    end.


%% @private 
-spec process(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().
    
process(#trans{stateless=false, opts=Opts}=UAS, Call) ->
    #trans{id=Id, method=Method, request=Req} = UAS,
    case nksip_call_uas_dialog:request(Req, Call) of
       {ok, DialogId, Call1} -> 
            % Caution: for first INVITEs, DialogId is not yet created!
            do_process(Method, DialogId, UAS, Call1);
        {error, Error} when Method=/='ACK' ->
            Reply = case Error of
                proceeding_uac ->
                    request_pending;
                proceeding_uas -> 
                    {500, [{<<"Retry-After">>, crypto:rand_uniform(0, 11)}], 
                                <<>>, [{reason, <<"Processing Previous INVITE">>}]};
                old_cseq ->
                    {internal_error, <<"Old CSeq in Dialog">>};
                _ ->
                    ?call_info("UAS ~p ~p dialog request error: ~p", 
                                [Id, Method, Error], Call),
                    no_transaction
            end,
            reply(Reply, UAS#trans{opts=[no_dialog|Opts]}, Call);
        {error, Error} when Method=:='ACK' ->
            ?call_notice("UAS ~p 'ACK' dialog request error: ~p", [Id, Error], Call),
            UAS1 = UAS#trans{status=finished},
            update(UAS1, Call)
    end;

process(#trans{stateless=true, method=Method}=UAS, Call) ->
    do_process(Method, <<>>, UAS, Call).


%% @private
-spec do_process(nksip:method(), nksip_dialog:id(), 
                 nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

do_process('INVITE', DialogId, UAS, Call) ->
    case DialogId of
        <<>> ->
            reply(no_transaction, UAS, Call);
        _ ->
            UAS1 = nksip_call_lib:expire_timer(expire, UAS, Call),
            #trans{request=#sipmsg{to_tag=ToTag}} = UAS,
            Fun = case ToTag of
                <<>> -> invite;
                _ -> reinvite
            end,
            do_process_call(Fun, UAS1, update(UAS1, Call))
    end;
    
do_process('ACK', DialogId, UAS, Call) ->
    UAS1 = UAS#trans{status=finished},
    case DialogId of
        <<>> -> 
            ?call_notice("received out-of-dialog ACK", [], Call),
            update(UAS1, Call);
        _ -> 
            do_process_call(ack, UAS1, update(UAS1, Call))
    end;

do_process('BYE', DialogId, UAS, Call) ->
    case DialogId of
        <<>> -> reply(no_transaction, UAS, Call);
        _ -> do_process_call(bye, UAS, Call)
    end;

do_process('OPTIONS', _DialogId, UAS, Call) ->
    do_process_call(options, UAS, Call); 

do_process('REGISTER', _DialogId, UAS, Call) ->
    do_process_call(register, UAS, Call); 

do_process(_Method, _DialogId, UAS, Call) ->
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    reply({method_not_allowed, nksip_sipapp_srv:allowed(Opts)}, UAS, Call).


%% @private
-spec do_process_call(atom(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

do_process_call(Fun, UAS, Call) ->
    #trans{request=#sipmsg{id=ReqId}, method=Method} = UAS,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    case app_call(Fun, [], UAS, Call) of
        {reply, _} when Method=:='ACK' ->
            update(UAS, Call);
        {reply, Reply} ->
            reply(Reply, UAS, Call);
        not_exported when Method=:='ACK' ->
            Call;
        not_exported ->
            {reply, Reply, _} = apply(nksip_sipapp, Fun, [ReqId, none, Opts]),
            reply(Reply, UAS, Call);
        #call{} = Call1 -> 
            Call1
    end.



%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec app_call(atom(), list(), nksip_call:trans(), nksip_call:call()) ->
    {reply, term()} | nksip_call:call() | not_exported.

app_call(Fun, Args, UAS, Call) ->
    #trans{id=Id, method=Method, status=Status, request=Req} = UAS,
    #call{app_id=AppId, opts=#call_opts{app_module=Module}} = Call,
    ?call_debug("UAS ~p ~p (~p) calling SipApp's ~p ~p", 
                [Id, Method, Status, Fun, Args], Call),
    From = {'fun', nksip_call, app_reply, [Fun, Id, self()]},
    Args1 = Args ++ [Req],
    Args2 = Args ++ [Req#sipmsg.id],
    case 
        nksip_sipapp_srv:sipapp_call(AppId, Module, Fun, Args1, Args2, From)
    of
        {reply, Reply} ->
            {reply, Reply};
        async -> 
            UAS1 = nksip_call_lib:app_timer(Fun, UAS, Call),
            update(UAS1, Call);
        not_exported ->
            not_exported;
        error ->
            reply({internal_error, <<"Error calling callback">>}, UAS, Call)
    end.


%% @private
-spec loop_id(nksip:request()) ->
    integer().
    
loop_id(Req) ->
    #sipmsg{
        app_id = AppId, 
        from_tag = FromTag, 
        call_id = CallId, 
        cseq = CSeq, 
        cseq_method = CSeqMethod
    } = Req,
    erlang:phash2({AppId, CallId, FromTag, CSeq, CSeqMethod}).


%% @private Sends a transaction reply
-spec reply(nksip:sipreply() | {nksip:response(), nksip_lib:proplist()}, 
            nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

reply(Reply, UAS, Call) ->
    nksip_call_uas_reply:reply(Reply, UAS, Call).


%% @private
-spec update(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

update(UAS, Call) ->
    nksip_call_lib:update(UAS, Call).



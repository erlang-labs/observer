%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2012. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
-module(observer_perf_wx).

-export([start_link/2]).

%% wx_object callbacks
-export([init/1, handle_info/2, terminate/2, code_change/3, handle_call/3,
	 handle_event/2, handle_sync_event/3, handle_cast/2]).

-behaviour(wx_object).
-include_lib("wx/include/wx.hrl").
-include("observer_defs.hrl").

-record(state,
	{
	  offset = 0.0,
	  active = false,
	  parent,
	  windows,
	  data = {0, queue:new()},
	  panel,
	  paint,
	  appmon
	}).

-define(wxGC, wxGraphicsContext).

-record(paint, {font, small, pen, pen2, pens}).

-define(RQ_W,  1).
-define(MEM_W, 2).
-define(IO_W,  3).

start_link(Notebook, Parent) ->
    wx_object:start_link(?MODULE, [Notebook, Parent], []).

init([Notebook, Parent]) ->
 try
    Panel = wxPanel:new(Notebook),
    Main  = wxBoxSizer:new(?wxVERTICAL),

    CPU = wxPanel:new(Panel, [{winid, ?RQ_W}, {style,?wxFULL_REPAINT_ON_RESIZE}]),
    wxWindow:setBackgroundColour(CPU, ?wxWHITE),
    wxSizer:add(Main, CPU, [{flag, ?wxEXPAND bor ?wxALL},
				 {proportion, 1}, {border, 5}]),
    MemIO = wxBoxSizer:new(?wxHORIZONTAL),
    MEM = wxPanel:new(Panel, [{winid, ?MEM_W}, {style,?wxFULL_REPAINT_ON_RESIZE}]),
    wxWindow:setBackgroundColour(MEM, ?wxWHITE),
    IO  = wxPanel:new(Panel, [{winid, ?IO_W}, {style,?wxFULL_REPAINT_ON_RESIZE}]),
    wxWindow:setBackgroundColour(IO, ?wxWHITE),
    wxSizer:add(MemIO, MEM, [{flag, ?wxEXPAND bor ?wxLEFT},
			     {proportion, 1}, {border, 5}]),
    wxSizer:add(MemIO, IO,  [{flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT},
			     {proportion, 1}, {border, 5}]),
    wxSizer:add(Main, MemIO, [{flag, ?wxEXPAND bor ?wxDOWN},
			      {proportion, 1}, {border, 5}]),
    wxWindow:setSizer(Panel, Main),

    wxPanel:connect(CPU, paint, [callback]),
    wxPanel:connect(IO, paint, [callback]),
    wxPanel:connect(MEM, paint, [callback]),

    % DefFont  = wxSystemSettings:getFont(?wxSYS_DEFAULT_GUI_FONT),
    %% DefSize = wxFont:getPointSize(DefFont),
    %% DefFamily = wxFont:getFamily(DefFont),
    %% Font = wxFont:new(DefSize, DefFamily, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
    Font = wxFont:new(12,?wxFONTFAMILY_DECORATIVE,?wxFONTSTYLE_NORMAL,?wxFONTWEIGHT_BOLD),
    SmallFont = wxFont:new(10, ?wxFONTFAMILY_DECORATIVE, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL),
    BlackPen = wxPen:new({0,0,0}, [{width, 2}]),
    Pens = [wxPen:new(Col, [{width, 2}]) || Col <- tuple_to_list(colors())],
    process_flag(trap_exit, true),
    {Panel, #state{parent=Parent,
		   panel =Panel,
		   windows = {CPU, MEM, IO},
		   paint=#paint{font = Font,
				small = SmallFont,
				pen  = ?wxGREY_PEN,
				pen2 = BlackPen,
				pens = list_to_tuple(Pens)
			       }
		  }}
   catch _:Err ->
	   io:format("~p crashed ~p: ~p~n",[?MODULE, Err, erlang:get_stacktrace()]),
	   {error, Err}
   end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_event(#wx{event=#wxCommand{type=command_menu_selected}},
	     State = #state{}) ->
    {noreply, State};

handle_event(Event, _State) ->
    error({unhandled_event, Event}).

%%%%%%%%%%
handle_sync_event(#wx{obj=Panel, event = #wxPaint{}},_,
		  #state{active=Active, offset=Offset, paint=Paint,
			 windows=Windows, data=Data}) ->
    %% PaintDC must be created in a callback to work on windows.
    %% Sigh workaround bug on MacOSX (Id in paint event is always 0)
    %% Panel = element(Id, Windows),
    Id = if Panel =:= element(?RQ_W, Windows)  -> ?RQ_W;
	    Panel =:= element(?MEM_W, Windows) -> ?MEM_W;
	    Panel =:= element(?IO_W, Windows)  -> ?IO_W
	 end,
    DC = wxPaintDC:new(Panel),
    GC = ?wxGC:create(DC),
    %% Nothing is drawn until wxPaintDC is destroyed.
    try
    draw(Offset, Id, GC, Panel, Paint, Data, Active)
    catch _:Err ->
	    io:format("Internal error ~p ~p~n",[Err, erlang:get_stacktrace()])
    end,
    ?wxGC:destroy(GC),
    wxPaintDC:destroy(DC),
    ok.
%%%%%%%%%%
handle_call(Event, From, _State) ->
    error({unhandled_call, Event, From}).

handle_cast(Event, _State) ->
    error({unhandled_cast, Event}).
%%%%%%%%%%
handle_info(Stats = {stats, 1, _, _, _},
	    State = #state{panel=Panel, data=Data, active=Active}) ->
    if Active ->
	    wxWindow:refresh(Panel),
	    Freq = 6,
	    erlang:send_after(trunc(1000 / Freq), self(), {refresh, 1, Freq});
       true -> ignore
    end,
    {noreply, State#state{offset=0.0, data = add_data(Stats, Data)}};

handle_info({refresh, Seq, Freq}, State = #state{panel=Panel, offset=Prev}) ->
    wxWindow:refresh(Panel),
    Next = Seq+1,
    if Seq > 1, Prev =:= 0.0 ->
	    %% We didn't have time to handle the refresh
	    {noreply, State};
       Next < Freq ->
	    erlang:send_after(trunc(1000 / Freq), self(), {refresh, Next, Freq}),
	    {noreply, State#state{offset=Seq/Freq}};
       true ->
	    {noreply, State#state{offset=Seq/Freq}}
    end;

handle_info({active, Node}, State = #state{parent=Parent, panel=Panel, appmon=Old}) ->
    create_menus(Parent, []),
    try
	Node = node(Old),
	wxWindow:refresh(Panel),
	{noreply, State#state{active=true}}
    catch _:_ ->
	    catch Old ! exit,
	    Me = self(),
	    Pid = spawn_link(Node, observer_backend, fetch_stats, [Me, 1000]),
	    wxWindow:refresh(Panel),
	    {noreply, State#state{active=true, appmon=Pid, data={0, queue:new()}}}
    end;

handle_info(not_active, State = #state{appmon=_Pid}) ->
    %% Pid ! exit,
    {noreply, State#state{active=false}};

handle_info({'EXIT', Old, _}, State = #state{appmon=Old}) ->
    {noreply, State#state{active=false, appmon=undefined}};

handle_info(_Event, State) ->
    %% io:format("~p:~p: ~p~n",[?MODULE,?LINE,_Event]),
    {noreply, State}.

%%%%%%%%%%
terminate(_Event, #state{appmon=Pid}) ->
    catch Pid ! exit,
    ok.
code_change(_, _, State) ->
    State.

add_data(Stats, {N, Q}) when N > 60 ->
    {N, queue:drop(queue:in(Stats, Q))};
add_data(Stats, {N, Q}) ->
    {N+1, queue:in(Stats, Q)}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

create_menus(Parent, _) ->
    MenuEntries =
	[{"File",
	  [
	  ]}
	],
    observer_wx:create_menus(Parent, MenuEntries).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
collect_data(?RQ_W, {N, Q}) ->
    case queue:to_list(Q) of
	[] ->  {0, 0, []};
	[_] ->  {0, 0, []};
	[{stats, _Ver, Init0, _IO, _Mem}|Data0] ->
	    Init = lists:sort(Init0),
	    [_|Data=[First|_]] = lists:foldl(fun({stats, _, T0, _, _}, [Prev|Acc]) ->
					   TN = lists:sort(T0),
					   Delta = calc_delta(TN, Prev),
					   [TN, list_to_tuple(Delta)|Acc]
				   end, [Init], Data0),
	    {N, lmax(Data), lists:reverse([First|Data])}
    end;
collect_data(?MEM_W, {N, Q}) ->
    MemT = mem_types(),
    Data = [list_to_tuple([Value || {Type,Value} <- MemInfo,
				    lists:member(Type, MemT)])
	    || {stats, _Ver, _RQ, _IO, MemInfo} <- queue:to_list(Q)],
    {N, lmax(Data), Data};
collect_data(?IO_W, {N, Q}) ->
    case queue:to_list(Q) of
	[] ->  {0, 0, []};
	[_] -> {0, 0, []};
	[{stats, _Ver, _RQ, {{_,In0}, {_,Out0}}, _Mem}|Data0] ->
	    [_,_|Data=[First|_]] =
		lists:foldl(fun({stats, _, _, {{_,In}, {_,Out}}, _}, [PIn,Pout|Acc]) ->
				    [In,Out,{In-PIn,Out-Pout}|Acc]
			    end, [In0,Out0], Data0),
	    {N, lmax(Data), lists:reverse([First|Data])}
    end.

mem_types() ->
    [total, processes, system, atom, binary, code, ets].

lmax([]) -> 0;
lmax(List) ->
    lists:max([lists:max(tuple_to_list(T)) || T <- List]).

calc_delta([{Id, WN, TN}|Ss], [{Id, WP, TP}|Ps]) ->
    [100*(WN-WP) div (TN-TP)|calc_delta(Ss, Ps)];
calc_delta([], []) -> [].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
draw(Offset, Id, DC, Panel, Paint=#paint{pens=Pens, small=Small}, Data, Active) ->
    %% This can be optimized a lot by collecting data once
    %% and draw to memory and then blit memory and only draw new entries in new memory
    %% area.  Hmm now rewritten to use ?wxGC I don't now if it is feasable.
    {Len, Max0, Hs} = collect_data(Id, Data),
    Max = calc_max(Max0),
    NoGraphs = try tuple_size(hd(Hs)) catch _:_ -> 0 end,
    Size = wxWindow:getClientSize(Panel),
    {X0,Y0,WS,HS} = draw_borders(Id, NoGraphs, DC, Size, Max, Paint),
    Last = 60*WS+X0-1,
    Start = max(61-Len, 0)*WS+X0 - Offset*WS,
    case Hs of
	[] -> ignore;
	[_] -> ignore;
	_ ->
	    Draw = fun(N) ->
			   Lines = make_lines(Hs, Start, N, {X0,Max*HS,Last}, Y0, WS, HS),
			   ?wxGC:setPen(DC, element(1+ ((N-1) rem tuple_size(Pens)), Pens)),
			   ?wxGC:strokeLines(DC, Lines),
			   N+1
		   end,
	    [Draw(I) || I <- lists:seq(NoGraphs, 1, -1)]
    end,
    case Active of
	false ->
	    NotActive = "Service not available",
	    ?wxGC:setFont(DC, Small, {0,0,0}),
	    ?wxGC:drawText(DC, NotActive, X0 + 100, element(2,Size) div 2);
	true ->
	    ignore
    end,
    ok.

make_lines(Ds = [Data|_], PX, N, Clip, ZeroY, WS, HS) ->
    Y = element(N,Data),
    make_lines(Ds, PX, N, Clip, ZeroY, WS, HS, Y, []).

make_lines([D1 | Ds = [D2|Rest]], PX, N, Clip={Cx,Cy, _}, ZeroY, WS, HS, Y0, Acc0) ->
    Y1 = element(N,D1),
    Y2 = element(N,D2),
    Y3 = case Rest of
	     [D3|_] -> element(N,D3);
	     [] -> Y2
	 end,
    This = {max(Cx, PX),ZeroY-min(Cy,Y1*HS)},
    Acc = if (abs(Y1-Y2) * HS) < 3.0 -> [This|Acc0];
	     WS < 3.0 -> [This|Acc0];
	     PX < Cx ->
		  make_splines(Y0,Y1,Y2,Y3,PX,Clip,ZeroY,WS,HS,Acc0);
	     true ->
		  make_splines(Y0,Y1,Y2,Y3,PX,Clip,ZeroY,WS,HS,[This|Acc0])
	  end,
    make_lines(Ds, PX+WS, N, Clip, ZeroY, WS, HS, Y1, Acc);
make_lines([D1],  _PX, N, {_,Cy,Last}, ZeroY, _WS, HS, _Y0, Acc) ->
    Y1 = element(N,D1),
    [{Last,ZeroY-min(Cy, Y1*HS)}|Acc].

make_splines(Y00,Y10,Y20,Y30,PX,Clip,ZeroY,WS,HS,Acc) ->
    Y1 = Y10*HS,
    Y2 = Y20*HS,
    Steps = min(abs(Y1-Y2), WS),
    if Steps > 2 ->
	    Y0 = Y00*HS,
	    Y3 = Y30*HS,
	    Tan = spline_tan(Y0,Y1,Y2,Y3),
	    Delta = 1/Steps,
	    splines(Steps-1, 0.0, Delta, Tan, Y1,Y2, PX, Clip,ZeroY, Delta*WS, Acc);
       true ->
	    Acc
    end.

splines(N, XD, XD0, Tan, Y1,Y2, PX0, Clip={Cx,Cy,_},ZeroY, WS, Acc) when N > 0 ->
    PX = PX0+WS,
    Delta = XD+XD0,
    if PX < Cx ->
	    splines(N-1, Delta, XD0, Tan, Y1, Y2, PX, Clip,ZeroY, WS, Acc);
       true ->
	    Y = min(Cy, max(0,spline(Delta, Tan, Y1,Y2))),
	    splines(N-1, Delta, XD0, Tan, Y1, Y2, PX, Clip,ZeroY, WS,
		    [{PX, ZeroY-Y}|Acc])
    end;
splines(_N, _XD, _XD0, _Tan, _Y1,_Y2, _PX, _Clip,_ZeroY, _WS, Acc) -> Acc.

spline(T, {M1, M2}, Y1, Y2) ->
    %% Hermite Basis Funcs
    T2 = T*T,  T3 = T*T*T,
    H1 = 2*T3-3*T2+1,
    H2 = -2*T3+3*T2,
    H3 = T3-2*T2+T,
    H4 = T3-T2,
    %% Result
    M1*H3 + Y1*H1 + Y2*H2 + M2*H4.

spline_tan(Y0, Y1, Y2, Y3) ->
    S = 1.0,
    C = 0.5,
    %% Calc tangent values
    M1 = S*C*(Y2-Y0),
    M2 = S*C*(Y3-Y1),
    {M1,M2}.

-define(BW, 5).
-define(BH, 5).

draw_borders(Type, NoGraphs, DC, {W,H}, Max,
	     #paint{pen=Pen, pen2=Pen2, font=Font, small=Small}) ->
    {Unit, MaxUnit} = bytes(Type, Max),
    Str1 = observer_lib:to_str(MaxUnit),
    Str2 = observer_lib:to_str(MaxUnit div 2),
    Str3 = observer_lib:to_str(0),

    ?wxGC:setFont(DC, Font, {0,0,0}),
    {TW,TH,_,_} = ?wxGC:getTextExtent(DC, Str1),
    {SpaceW, _,_,_} = ?wxGC:getTextExtent(DC, "W"),

    GraphX0 = ?BW+TW+?BW,
    GraphX1 = W-?BW*4,
    TopTextX = ?BW+TW+?BW,
    MaxTextY = ?BH+TH+?BH,
    BottomTextY = H-?BH-TH,
    SecondsY = BottomTextY - ?BH - TH,
    GraphY0 = MaxTextY + (TH / 2),
    GraphY1 = SecondsY - ?BH,
    GraphW = GraphX1-GraphX0-1,
    GraphH = GraphY1-GraphY0-1,
    GraphY25 = GraphY0 + (GraphY1 - GraphY0) / 4,
    GraphY50 = GraphY0 + (GraphY1 - GraphY0) / 2,
    GraphY75 = GraphY0 + 3*(GraphY1 - GraphY0) / 4,
    ScaleW = GraphW / 60,
    ScaleH = GraphH / Max,

    ?wxGC:setFont(DC, Small, {0,0,0}),
    Align = fun(Str, Y) ->
		    {StrW, _, _, _} = ?wxGC:getTextExtent(DC, Str),
		    ?wxGC:drawText(DC, Str, GraphX0 - StrW - ?BW, Y)
	    end,
    Align(Str1, MaxTextY),
    Align(Str2, GraphY50 - (TH / 2)),
    Align(Str3, GraphY1 - (TH / 2) + 1),

    ?wxGC:setPen(DC, Pen),
    DrawSecs = fun(Secs, Pos) ->
		       Str = [observer_lib:to_str(Secs)|" s"],
		       X = GraphX0+Pos,
		       ?wxGC:drawText(DC, Str,  X-SpaceW, SecondsY),
		       ?wxGC:strokeLine(DC, X, GraphY0, X, GraphY1+5),
		       Pos + 10*ScaleW
	       end,
    lists:foldl(DrawSecs, 0, lists:seq(60,0, -10)),

    ?wxGC:strokeLine(DC, GraphX0-3, GraphY25, GraphX1, GraphY25),
    ?wxGC:strokeLine(DC, GraphX0-3, GraphY50, GraphX1, GraphY50),
    ?wxGC:strokeLine(DC, GraphX0-3, GraphY75, GraphX1, GraphY75),

    ?wxGC:setPen(DC, Pen2),
    ?wxGC:strokeLines(DC, [{GraphX0, GraphY0-1}, {GraphX0, GraphY1+1},
			   {GraphX1, GraphY1+1}, {GraphX1, GraphY0-1},
			   {GraphX0, GraphY0-1}]),

    ?wxGC:setFont(DC, Font, {0,0,0}),
    case Type of
	?RQ_W ->  ?wxGC:drawText(DC, "Scheduler Utilization (%) ", TopTextX,?BH);
	?MEM_W -> ?wxGC:drawText(DC, "Memory Usage " ++ Unit, TopTextX,?BH);
	?IO_W ->  ?wxGC:drawText(DC, "IO Usage " ++ Unit, TopTextX,?BH)
    end,

    Text = fun(X,Y, Str, PenId) ->
		   if PenId == 0 ->
			   ?wxGC:setFont(DC, Font, {0,0,0});
		      PenId > 0 ->
			   Id = 1 + ((PenId-1) rem tuple_size(colors())),
			   ?wxGC:setFont(DC, Font, element(Id, colors()))
		   end,
		   ?wxGC:drawText(DC, Str, X, Y),
		   {StrW, _, _, _} = ?wxGC:getTextExtent(DC, Str),
		   StrW + X + SpaceW
	   end,
    case Type of
	?RQ_W ->
	    TN0 = Text(?BW, BottomTextY, "Scheduler: ", 0),
	    lists:foldl(fun(Id, Pos0) ->
				Text(Pos0, BottomTextY, integer_to_list(Id), Id)
			end, TN0, lists:seq(1, NoGraphs));
	?MEM_W ->
	    lists:foldl(fun(MType, {PenId, Pos0}) ->
				Str = uppercase(atom_to_list(MType)),
				Pos = Text(Pos0, BottomTextY, Str, PenId),
				{PenId+1, Pos}
			end, {1, ?BW}, mem_types());
	?IO_W ->
	    TN0 = Text(?BW, BottomTextY, "Input", 1),
	    Text(TN0, BottomTextY, "Output", 2)
    end,
    {GraphX0+1, GraphY1, ScaleW, ScaleH}.

uppercase([C|Rest]) ->
    [C-$a+$A|Rest].

calc_max(Max) when Max < 10 -> 10;
calc_max(Max) -> calc_max1(Max).

calc_max1(Max) ->
    case Max div 10 of
	X when X < 10 ->
	    case Max rem 10 of
		0 -> Max;
		_ ->
		    (X+1)*10
	    end;
	X ->
	    10*calc_max1(X)
    end.

bytes(?RQ_W, Val) -> {"", Val};
bytes(_, B) ->
    KB = B div 1024,
    MB = KB div 1024,
    GB = MB div 1024,
    if
	GB > 10 -> {"(GB)", GB};
	MB > 10 -> {"(MB)", MB};
	KB >  0 -> {"(KB)", KB};
	true    -> {"(B)", B}
    end.

colors() ->
    {{200, 50, 50}, {50, 200, 50}, {50, 50, 200},
     {255, 110, 0}, {50, 200, 200}, {200, 50, 200},
     {240, 200, 80}, {140, 2, 140},
     {100, 200, 240}, {100, 240, 100}
    }.
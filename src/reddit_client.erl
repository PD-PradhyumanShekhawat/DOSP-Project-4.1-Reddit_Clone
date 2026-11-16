
-module(reddit_client).

-export([
    start_link/1,
    stop/1,
    register/2,
    create_subreddit/3,
    join_subreddit/3,
    leave_subreddit/3,
    subreddit_info/2,
    create_post/4,
    get_feed/2,
    add_comment/5,
    get_post_comments/2
]).

start_link(EnginePid) when is_pid(EnginePid) ->
    spawn_link(fun() -> loop(EnginePid) end).

stop(ClientPid) when is_pid(ClientPid) ->
    ClientPid ! stop,
    ok.

register(ClientPid, Username) ->
    call(ClientPid, {register, Username}).

create_subreddit(ClientPid, Username, SubredditName) ->
    call(ClientPid, {create_subreddit, Username, SubredditName}).

join_subreddit(ClientPid, Username, SubredditName) ->
    call(ClientPid, {join_subreddit, Username, SubredditName}).

leave_subreddit(ClientPid, Username, SubredditName) ->
    call(ClientPid, {leave_subreddit, Username, SubredditName}).

subreddit_info(ClientPid, SubredditName) ->
    call(ClientPid, {subreddit_info, SubredditName}).

create_post(ClientPid, Username, SubredditName, Content) ->
    call(ClientPid, {create_post, Username, SubredditName, Content}).

get_feed(ClientPid, Username) ->
    call(ClientPid, {get_feed, Username}).

add_comment(ClientPid, Username, PostId, ParentCommentId, Content) ->
    call(
        ClientPid,
        {add_comment, Username, PostId, ParentCommentId, Content}
    ).

get_post_comments(ClientPid, PostId) ->
    call(ClientPid, {get_post_comments, PostId}).

call(ClientPid, Request) ->
    Ref = make_ref(),
    ClientPid ! {call, self(), Ref, Request},

    receive
        {client_reply, Ref, Result} ->
            Result
    after 6000 ->
        {error, timeout}
    end.

loop(EnginePid) ->
    receive
        {call, From, Ref, Request} ->
            EngineRef = make_ref(),
            EnginePid ! {request, self(), EngineRef, Request},

            receive
                {reply, EngineRef, Result} ->
                    From ! {client_reply, Ref, Result},
                    loop(EnginePid)
            after 5500 ->
                From ! {client_reply, Ref, {error, engine_timeout}},
                loop(EnginePid)
            end;

        stop ->
            ok;

        _UnexpectedMessage ->
            loop(EnginePid)
    end.

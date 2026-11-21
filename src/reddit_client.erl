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
    repost/3,
    get_user_reposts/2,
    get_feed/2,
    add_comment/5,
    get_post_comments/2,
    vote_post/4,
    vote_comment/4,
    get_post_score/2,
    get_comment_score/2,
    get_karma/2,
    send_message/4,
    get_inbox/2,
    get_sent_messages/2,
    get_conversation/3,
    reply_to_message/4
]).

start_link(EnginePid) when is_pid(EnginePid) ->
    spawn_link(fun() -> loop(EnginePid) end).

stop(ClientPid) when is_pid(ClientPid) ->
    ClientPid ! stop,
    ok.

register(ClientPid, Username) ->
    call(ClientPid, {register, Username}).

create_subreddit(ClientPid, Username, Name) ->
    call(ClientPid, {create_subreddit, Username, Name}).

join_subreddit(ClientPid, Username, Name) ->
    call(ClientPid, {join_subreddit, Username, Name}).

leave_subreddit(ClientPid, Username, Name) ->
    call(ClientPid, {leave_subreddit, Username, Name}).

subreddit_info(ClientPid, Name) ->
    call(ClientPid, {subreddit_info, Name}).

create_post(ClientPid, Username, Name, Content) ->
    call(ClientPid, {create_post, Username, Name, Content}).

repost(ClientPid, Username, PostId) ->
    call(ClientPid, {repost, Username, PostId}).

get_user_reposts(ClientPid, Username) ->
    call(ClientPid, {get_user_reposts, Username}).

get_feed(ClientPid, Username) ->
    call(ClientPid, {get_feed, Username}).

add_comment(ClientPid, Username, PostId, ParentId, Content) ->
    call(
        ClientPid,
        {add_comment, Username, PostId, ParentId, Content}
    ).

get_post_comments(ClientPid, PostId) ->
    call(ClientPid, {get_post_comments, PostId}).

vote_post(ClientPid, Username, PostId, Vote) ->
    call(ClientPid, {vote_post, Username, PostId, Vote}).

vote_comment(ClientPid, Username, CommentId, Vote) ->
    call(ClientPid, {vote_comment, Username, CommentId, Vote}).

get_post_score(ClientPid, PostId) ->
    call(ClientPid, {get_post_score, PostId}).

get_comment_score(ClientPid, CommentId) ->
    call(ClientPid, {get_comment_score, CommentId}).

get_karma(ClientPid, Username) ->
    call(ClientPid, {get_karma, Username}).

send_message(ClientPid, Sender, Recipient, Content) ->
    call(ClientPid, {send_message, Sender, Recipient, Content}).

get_inbox(ClientPid, Username) ->
    call(ClientPid, {get_inbox, Username}).

get_sent_messages(ClientPid, Username) ->
    call(ClientPid, {get_sent_messages, Username}).

get_conversation(ClientPid, Username, OtherUsername) ->
    call(ClientPid, {get_conversation, Username, OtherUsername}).

reply_to_message(ClientPid, Sender, ParentMessageId, Content) ->
    call(
        ClientPid,
        {reply_to_message, Sender, ParentMessageId, Content}
    ).

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
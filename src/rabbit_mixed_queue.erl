%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_mixed_queue).

-include("rabbit.hrl").

-export([init/2]).

-export([publish/2, publish_delivered/2, fetch/1, ack/2,
         tx_publish/2, tx_commit/3, tx_rollback/2, requeue/2, purge/1,
         len/1, is_empty/1, delete_queue/1, maybe_prefetch/1]).

-export([set_storage_mode/3, storage_mode/1,
         estimate_queue_memory_and_reset_counters/1]).

-record(mqstate, { mode,
                   msg_buf,
                   queue,
                   is_durable,
                   length,
                   memory_size,
                   memory_gain,
                   memory_loss,
                   prefetcher
                 }
       ).

-define(TO_DISK_MAX_FLUSH_SIZE, 100000).

-ifdef(use_specs).

-type(mode() :: ( 'disk' | 'mixed' )).
-type(mqstate() :: #mqstate { mode :: mode(),
                              msg_buf :: queue(),
                              queue :: queue_name(),
                              is_durable :: boolean(),
                              length :: non_neg_integer(),
                              memory_size :: (non_neg_integer() | 'undefined'),
                              memory_gain :: (non_neg_integer() | 'undefined'),
                              memory_loss :: (non_neg_integer() | 'undefined'),
                              prefetcher :: (pid() | 'undefined')
                            }).
-type(acktag() :: ( 'no_on_disk' | { non_neg_integer(), non_neg_integer() })).
-type(okmqs() :: {'ok', mqstate()}).

-spec(init/2 :: (queue_name(), boolean()) -> okmqs()).
-spec(publish/2 :: (message(), mqstate()) -> okmqs()).
-spec(publish_delivered/2 :: (message(), mqstate()) ->
             {'ok', acktag(), mqstate()}).
-spec(fetch/1 :: (mqstate()) ->
             {('empty' | {message(), boolean(), acktag(), non_neg_integer()}),
              mqstate()}).
-spec(ack/2 :: ([{message(), acktag()}], mqstate()) -> okmqs()).
-spec(tx_publish/2 :: (message(), mqstate()) -> okmqs()).
-spec(tx_commit/3 :: ([message()], [acktag()], mqstate()) -> okmqs()).
-spec(tx_rollback/2 :: ([message()], mqstate()) -> okmqs()).
-spec(requeue/2 :: ([{message(), acktag()}], mqstate()) -> okmqs()).
-spec(purge/1 :: (mqstate()) -> okmqs()).
             
-spec(delete_queue/1 :: (mqstate()) -> {'ok', mqstate()}).
             
-spec(len/1 :: (mqstate()) -> non_neg_integer()).
-spec(is_empty/1 :: (mqstate()) -> boolean()).

-spec(set_storage_mode/3 :: (mode(), [message()], mqstate()) -> okmqs()).

-spec(estimate_queue_memory_and_reset_counters/1 :: (mqstate()) ->
             {mqstate(), non_neg_integer(), non_neg_integer(),
              non_neg_integer()}).
-spec(storage_mode/1 :: (mqstate()) -> mode()).

-endif.

init(Queue, IsDurable) ->
    Len = rabbit_disk_queue:len(Queue),
    MsgBuf = inc_queue_length(queue:new(), Len),
    Size = rabbit_disk_queue:foldl(
             fun (Msg = #basic_message { is_persistent = true },
                  _AckTag, _IsDelivered, Acc) ->
                     Acc + size_of_message(Msg)
             end, 0, Queue),
    {ok, #mqstate { mode = disk, msg_buf = MsgBuf, queue = Queue,
                    is_durable = IsDurable, length = Len,
                    memory_size = Size, memory_gain = undefined,
                    memory_loss = undefined, prefetcher = undefined }}.

size_of_message(
  #basic_message { content = #content { payload_fragments_rev = Payload }}) ->
    lists:foldl(fun (Frag, SumAcc) ->
                        SumAcc + size(Frag)
                end, 0, Payload).

set_storage_mode(Mode, _TxnMessages, State = #mqstate { mode = Mode }) ->
    {ok, State};
set_storage_mode(disk, TxnMessages, State =
         #mqstate { mode = mixed, queue = Q, msg_buf = MsgBuf,
                    is_durable = IsDurable, prefetcher = Prefetcher }) ->
    State1 = State #mqstate { mode = disk },
    MsgBuf1 =
        case Prefetcher of
            undefined -> MsgBuf;
            _ ->
                case rabbit_queue_prefetcher:drain_and_stop(Prefetcher) of
                    empty -> MsgBuf;
                    {Fetched, Len} ->
                        MsgBuf2 = dec_queue_length(MsgBuf, Len),
                        queue:join(Fetched, MsgBuf2)
                end
        end,
    %% We enqueue _everything_ here. This means that should a message
    %% already be in the disk queue we must remove it and add it back
    %% in. Fortunately, by using requeue, we avoid rewriting the
    %% message on disk.
    %% Note we also batch together messages on disk so that we minimise
    %% the calls to requeue.
    {ok, MsgBuf3} =
        send_messages_to_disk(IsDurable, Q, MsgBuf1, 0, 0, [], [], queue:new()),
    %% tx_publish txn messages. Some of these will have been already
    %% published if they really are durable and persistent which is
    %% why we can't just use our own tx_publish/2 function (would end
    %% up publishing twice, so refcount would go wrong in disk_queue).
    lists:foreach(
      fun (Msg = #basic_message { is_persistent = IsPersistent }) ->
              ok = case IsDurable andalso IsPersistent of
                       true -> ok;
                       _    -> rabbit_disk_queue:tx_publish(Msg)
                   end
      end, TxnMessages),
    garbage_collect(),
    {ok, State1 #mqstate { msg_buf = MsgBuf3, prefetcher = undefined }};
set_storage_mode(mixed, TxnMessages, State =
                 #mqstate { mode = disk, is_durable = IsDurable }) ->
    %% The queue has a token just saying how many msgs are on disk
    %% (this is already built for us when in disk mode).
    %% Don't actually do anything to the disk
    %% Don't start prefetcher just yet because the queue maybe busy -
    %% wait for hibernate timeout in the amqqueue_process.
    
    %% Remove txn messages from disk which are neither persistent and
    %% durable. This is necessary to avoid leaks. This is also pretty
    %% much the inverse behaviour of our own tx_rollback/2 which is why
    %% we're not using it.
    Cancel =
        lists:foldl(
          fun (Msg = #basic_message { is_persistent = IsPersistent }, Acc) ->
                  case IsDurable andalso IsPersistent of
                      true  -> Acc;
                      false -> [Msg #basic_message.guid | Acc]
                  end
          end, [], TxnMessages),
    ok = if Cancel == [] -> ok;
            true -> rabbit_disk_queue:tx_rollback(Cancel)
         end,
    garbage_collect(),
    {ok, State #mqstate { mode = mixed }}.

send_messages_to_disk(IsDurable, Q, Queue, PublishCount, RequeueCount,
                      Commit, Ack, MsgBuf) ->
    case queue:out(Queue) of
        {empty, _Queue} ->
            ok = flush_messages_to_disk_queue(Q, Commit, Ack),
            {[], []} = flush_requeue_to_disk_queue(Q, RequeueCount, [], []),
            {ok, MsgBuf};
        {{value, {Msg = #basic_message { is_persistent = IsPersistent },
                  IsDelivered}}, Queue1} ->
            case IsDurable andalso IsPersistent of
                true -> %% it's already in the Q
                    send_messages_to_disk(
                      IsDurable, Q, Queue1, PublishCount, RequeueCount + 1,
                      Commit, Ack, inc_queue_length(MsgBuf, 1));
                false ->
                    republish_message_to_disk_queue(
                      IsDurable, Q, Queue1, PublishCount, RequeueCount, Commit,
                      Ack, MsgBuf, Msg, IsDelivered)
            end;
        {{value, {Msg, IsDelivered, AckTag}}, Queue1} ->
            %% these have come via the prefetcher, so are no longer in
            %% the disk queue so they need to be republished
            republish_message_to_disk_queue(
              IsDurable, Q, Queue1, PublishCount, RequeueCount, Commit,
              [AckTag | Ack], MsgBuf, Msg, IsDelivered);
        {{value, {on_disk, Count}}, Queue1} ->
            send_messages_to_disk(IsDurable, Q, Queue1, PublishCount,
                                  RequeueCount + Count, Commit, Ack,
                                  inc_queue_length(MsgBuf, Count))
    end.

republish_message_to_disk_queue(IsDurable, Q, Queue, PublishCount, RequeueCount,
                                Commit, Ack, MsgBuf, Msg =
                                #basic_message { guid = MsgId }, IsDelivered) ->
    {Commit1, Ack1} = flush_requeue_to_disk_queue(Q, RequeueCount, Commit, Ack),
    ok = rabbit_disk_queue:tx_publish(Msg),
    {PublishCount1, Commit2, Ack2} =
        case PublishCount == ?TO_DISK_MAX_FLUSH_SIZE of
            true  -> ok = flush_messages_to_disk_queue(
                            Q, [{MsgId, IsDelivered} | Commit1], Ack1),
                     {0, [], []};
            false -> {PublishCount + 1, [{MsgId, IsDelivered} | Commit1], Ack1}
        end,
    send_messages_to_disk(IsDurable, Q, Queue, PublishCount1, 0,
                          Commit2, Ack2, inc_queue_length(MsgBuf, 1)).

flush_messages_to_disk_queue(_Q, [], []) ->
    ok;
flush_messages_to_disk_queue(Q, Commit, Ack) ->
    rabbit_disk_queue:tx_commit(Q, lists:reverse(Commit), Ack).

flush_requeue_to_disk_queue(_Q, 0, Commit, Ack) ->
    {Commit, Ack};
flush_requeue_to_disk_queue(Q, RequeueCount, Commit, Ack) ->
    ok = flush_messages_to_disk_queue(Q, Commit, Ack),
    ok = rabbit_disk_queue:filesync(),
    ok = rabbit_disk_queue:requeue_next_n(Q, RequeueCount),
    {[], []}.

gain_memory(Inc, State = #mqstate { memory_size = QSize,
                                    memory_gain = Gain }) ->
    State #mqstate { memory_size = QSize + Inc,
                     memory_gain = Gain + Inc }.

lose_memory(Dec, State = #mqstate { memory_size = QSize,
                                    memory_loss = Loss }) ->
    State #mqstate { memory_size = QSize - Dec,
                     memory_loss = Loss + Dec }.

inc_queue_length(MsgBuf, 0) ->
    MsgBuf;
inc_queue_length(MsgBuf, Count) ->
    {NewCount, MsgBufTail} =
        case queue:out_r(MsgBuf) of
            {empty, MsgBuf1}                   -> {Count, MsgBuf1};
            {{value, {on_disk, Len}}, MsgBuf1} -> {Len + Count, MsgBuf1};
            {{value, _}, _MsgBuf1}             -> {Count, MsgBuf}
        end,
    queue:in({on_disk, NewCount}, MsgBufTail).

dec_queue_length(MsgBuf, Count) ->
    case queue:out(MsgBuf) of
        {{value, {on_disk, Len}}, MsgBuf1} ->
            case Len of
                Count ->
                    MsgBuf1;
                _ when Len > Count ->
                    queue:in_r({on_disk, Len-Count}, MsgBuf1)
            end;
        _ -> MsgBuf
    end.

maybe_prefetch(State = #mqstate { prefetcher = undefined,
                                  mode = mixed,
                                  msg_buf = MsgBuf,
                                  queue = Q }) ->
    case queue:peek(MsgBuf) of
        {value, {on_disk, Count}} ->
            %% only prefetch for the next contiguous block on
            %% disk. Beyond there, we either hit the end of the queue,
            %% or the next msg is already in RAM, held by us, the
            %% mixed queue
            {ok, Prefetcher} = rabbit_queue_prefetcher:start_link(Q, Count),
            State #mqstate { prefetcher = Prefetcher };
        _ -> State
    end;
maybe_prefetch(State) ->
    State.

on_disk(disk, _IsDurable, _IsPersistent)  -> true;
on_disk(mixed, true, true)                -> true;
on_disk(mixed, _IsDurable, _IsPersistent) -> false.

publish(Msg = #basic_message { is_persistent = IsPersistent }, State = 
        #mqstate { queue = Q, mode = Mode, is_durable = IsDurable,
                   msg_buf = MsgBuf, length = Length }) ->
    ok = case on_disk(Mode, IsDurable, IsPersistent) of
             true  -> rabbit_disk_queue:publish(Q, Msg, false);
             false -> ok
         end,
    MsgBuf1 = case Mode of
                  disk  -> inc_queue_length(MsgBuf, 1);
                  mixed -> queue:in({Msg, false}, MsgBuf)
              end,
    {ok, gain_memory(size_of_message(Msg),
                     State #mqstate { msg_buf = MsgBuf1,
                                      length = Length + 1 })}.

%% Assumption here is that the queue is empty already (only called via
%% attempt_immediate_delivery).
publish_delivered(Msg = #basic_message { guid = MsgId,
                                         is_persistent = IsPersistent},
                  State = #mqstate { is_durable = IsDurable, queue = Q,
                                     length = 0 })
  when IsDurable andalso IsPersistent ->
    ok = rabbit_disk_queue:publish(Q, Msg, true),
    State1 = gain_memory(size_of_message(Msg), State),
    %% must call phantom_fetch otherwise the msg remains at the head
    %% of the queue. This is synchronous, but unavoidable as we need
    %% the AckTag
    {MsgId, IsPersistent, true, AckTag, 0} = rabbit_disk_queue:phantom_fetch(Q),
    {ok, AckTag, State1};
publish_delivered(Msg, State = #mqstate { length = 0 }) ->
    {ok, not_on_disk, gain_memory(size_of_message(Msg), State)}.

fetch(State = #mqstate { length = 0 }) ->
    {empty, State};
fetch(State = #mqstate { msg_buf = MsgBuf, queue = Q,
                         is_durable = IsDurable, length = Length,
                         prefetcher = Prefetcher }) ->
    {{value, Value}, MsgBuf1} = queue:out(MsgBuf),
    Rem = Length - 1,
    State1 = State #mqstate { length = Rem },
    case Value of
        {Msg = #basic_message { guid = MsgId, is_persistent = IsPersistent },
         IsDelivered} ->
            AckTag =
                case IsDurable andalso IsPersistent of
                    true ->
                        {MsgId, IsPersistent, IsDelivered, AckTag1, _PRem}
                            = rabbit_disk_queue:phantom_fetch(Q),
                        AckTag1;
                    false ->
                        not_on_disk
                end,
            {{Msg, IsDelivered, AckTag, Rem},
             State1 #mqstate { msg_buf = MsgBuf1 }};
        {Msg = #basic_message { is_persistent = IsPersistent },
         IsDelivered, AckTag} ->
            %% message has come via the prefetcher, thus it's been
            %% delivered. If it's not persistent+durable, we should
            %% ack it now
            AckTag1 = maybe_ack(Q, IsDurable, IsPersistent, AckTag),
            {{Msg, IsDelivered, AckTag1, Rem},
             State1 #mqstate { msg_buf = MsgBuf1 }};
        _ when Prefetcher == undefined ->
            MsgBuf2 = dec_queue_length(MsgBuf, 1),
            {Msg = #basic_message { is_persistent = IsPersistent },
             IsDelivered, AckTag, _PersistRem}
                = rabbit_disk_queue:fetch(Q),
            AckTag1 = maybe_ack(Q, IsDurable, IsPersistent, AckTag),
            {{Msg, IsDelivered, AckTag1, Rem},
             State1 #mqstate { msg_buf = MsgBuf2 }};
        _ ->
            %% use State, not State1 as we've not dec'd length
            fetch(case rabbit_queue_prefetcher:drain(Prefetcher) of
                      empty -> State #mqstate { prefetcher = undefined };
                      {Fetched, Len, Status} ->
                          MsgBuf2 = dec_queue_length(MsgBuf, Len),
                          State #mqstate
                            { msg_buf = queue:join(Fetched, MsgBuf2),
                              prefetcher = case Status of
                                               finished -> undefined;
                                               continuing -> Prefetcher
                                           end }
                  end)
    end.

maybe_ack(_Q, true, true, AckTag) ->
    AckTag;
maybe_ack(Q, _, _, AckTag) ->
    ok = rabbit_disk_queue:ack(Q, [AckTag]),
    not_on_disk.

remove_diskless(MsgsWithAcks) ->
    lists:foldl(
      fun ({Msg, AckTag}, {AccAckTags, AccSize}) ->
              {case AckTag of
                   not_on_disk -> AccAckTags;
                   _ -> [AckTag | AccAckTags]
               end, size_of_message(Msg) + AccSize}
      end, {[], 0}, MsgsWithAcks).

ack(MsgsWithAcks, State = #mqstate { queue = Q }) ->
    {AckTags, ASize} = remove_diskless(MsgsWithAcks),
    ok = case AckTags of
             [] -> ok;
             _ -> rabbit_disk_queue:ack(Q, AckTags)
         end,
    {ok, lose_memory(ASize, State)}.
                                                   
tx_publish(Msg = #basic_message { is_persistent = IsPersistent },
           State = #mqstate { mode = Mode, is_durable = IsDurable }) ->
    ok = case on_disk(Mode, IsDurable, IsPersistent) of
             true  -> rabbit_disk_queue:tx_publish(Msg);
             false -> ok
         end,
    {ok, gain_memory(size_of_message(Msg), State)}.

tx_commit(Publishes, MsgsWithAcks,
          State = #mqstate { mode = Mode, queue = Q, msg_buf = MsgBuf,
                             is_durable = IsDurable, length = Length }) ->
    PersistentPubs =
        [{MsgId, false} ||
            #basic_message { guid = MsgId,
                             is_persistent = IsPersistent } <- Publishes,
            on_disk(Mode, IsDurable, IsPersistent)],
    {RealAcks, ASize} = remove_diskless(MsgsWithAcks),
    ok = case {PersistentPubs, RealAcks} of
             {[], []} -> ok;
             _        -> rabbit_disk_queue:tx_commit(
                           Q, PersistentPubs, RealAcks)
         end,
    Len = length(Publishes),
    MsgBuf1 = case Mode of
                  disk  -> inc_queue_length(MsgBuf, Len);
                  mixed -> ToAdd = [{Msg, false} || Msg <- Publishes],
                           queue:join(MsgBuf, queue:from_list(ToAdd))
              end,
    {ok, lose_memory(ASize, State #mqstate { msg_buf = MsgBuf1,
                                             length = Length + Len })}.

tx_rollback(Publishes,
            State = #mqstate { mode = Mode, is_durable = IsDurable }) ->
    {PersistentPubs, CSize} =
        lists:foldl(
          fun (Msg = #basic_message { is_persistent = IsPersistent,
                                      guid = MsgId }, {Acc, CSizeAcc}) ->
                  CSizeAcc1 = CSizeAcc + size_of_message(Msg),
                  {case on_disk(Mode, IsDurable, IsPersistent) of
                       true -> [MsgId | Acc];
                       _    -> Acc
                   end, CSizeAcc1}
          end, {[], 0}, Publishes),
    ok = case PersistentPubs of
             [] -> ok;
             _  -> rabbit_disk_queue:tx_rollback(PersistentPubs)
         end,
    {ok, lose_memory(CSize, State)}.

%% [{Msg, AckTag}]
requeue(MsgsWithAckTags,
        State = #mqstate { mode = Mode, queue = Q, msg_buf = MsgBuf,
                           is_durable = IsDurable, length = Length }) ->
    RQ = lists:foldl(
           fun ({Msg = #basic_message { is_persistent = IsPersistent }, AckTag},
                RQAcc) ->
                   case IsDurable andalso IsPersistent of
                       true ->
                           [{AckTag, true} | RQAcc];
                       false ->
                           case Mode of
                               mixed ->
                                   RQAcc;
                               disk when not_on_disk =:= AckTag ->
                                   ok = case RQAcc of
                                            [] -> ok;
                                            _  -> rabbit_disk_queue:requeue
                                                    (Q, lists:reverse(RQAcc))
                                        end,
                                   ok = rabbit_disk_queue:publish(Q, Msg, true),
                                   []
                           end
                   end
           end, [], MsgsWithAckTags),
    ok = case RQ of
             [] -> ok;
             _  -> rabbit_disk_queue:requeue(Q, lists:reverse(RQ))
         end,
    Len = length(MsgsWithAckTags),
    MsgBuf1 = case Mode of
                  mixed -> ToAdd = [{Msg, true} || {Msg, _} <- MsgsWithAckTags],
                           queue:join(MsgBuf, queue:from_list(ToAdd));
                  disk  -> inc_queue_length(MsgBuf, Len)
              end,
    {ok, State #mqstate { msg_buf = MsgBuf1, length = Length + Len }}.

purge(State = #mqstate { queue = Q, mode = Mode, length = Count,
                         prefetcher = Prefetcher, memory_size = QSize }) ->
    PurgedFromDisk = rabbit_disk_queue:purge(Q),
    Count = case Mode of
                disk ->
                    PurgedFromDisk;
                mixed ->
                    ok = case Prefetcher of
                             undefined -> ok;
                             _ -> rabbit_queue_prefetcher:stop(Prefetcher)
                         end,
                    Count
            end,
    {Count, lose_memory(QSize, State #mqstate { msg_buf = queue:new(),
                                                length = 0,
                                                prefetcher = undefined })}.

delete_queue(State = #mqstate { queue = Q, memory_size = QSize,
                                prefetcher = Prefetcher
                              }) ->
    ok = case Prefetcher of
             undefined -> ok;
             _ -> rabbit_queue_prefetcher:stop(Prefetcher)
         end,
    ok = rabbit_disk_queue:delete_queue(Q),
    {ok, lose_memory(QSize, State #mqstate { length = 0, msg_buf = queue:new(),
                                             prefetcher = undefined })}.

len(#mqstate { length = Length }) ->
    Length.

is_empty(#mqstate { length = Length }) ->
    0 == Length.

estimate_queue_memory_and_reset_counters(State =
  #mqstate { memory_size = Size, memory_gain = Gain, memory_loss = Loss }) ->
    {State #mqstate { memory_gain = 0, memory_loss = 0 }, 4 * Size, Gain, Loss}.

storage_mode(#mqstate { mode = Mode }) ->
    Mode.

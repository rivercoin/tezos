(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Utils
open Logging.RPC

module Services = Node_rpc_services

let filter_bi include_ops (bi: Services.Blocks.block_info)  =
  if include_ops then bi else { bi with operations = None }

let register_bi_dir node dir =
  let dir =
    let implementation b include_ops =
      Node.RPC.block_info node b >>= fun bi ->
      RPC.Answer.return (filter_bi include_ops bi) in
    RPC.register1 dir
      Services.Blocks.info implementation in
  let dir =
    let implementation b () =
      Node.RPC.block_info node b >>= fun bi ->
      RPC.Answer.return bi.hash in
    RPC.register1 dir
      Services.Blocks.hash
      implementation in
  let dir =
    let implementation b () =
      Node.RPC.block_info node b >>= fun bi ->
      RPC.Answer.return bi.net in
    RPC.register1 dir
      Services.Blocks.net implementation in
  let dir =
    let implementation b () =
      Node.RPC.block_info node b >>= fun bi ->
      RPC.Answer.return bi.predecessor in
    RPC.register1 dir
      Services.Blocks.predecessor implementation in
  let dir =
    let implementation b () =
      Node.RPC.block_info node b >>= fun bi ->
      RPC.Answer.return bi.fitness in
    RPC.register1 dir
      Services.Blocks.fitness implementation in
  let dir =
    let implementation b () =
      Node.RPC.block_info node b >>= fun bi ->
      RPC.Answer.return bi.timestamp in
    RPC.register1 dir
      Services.Blocks.timestamp implementation in
  let dir =
    let implementation b () =
      Node.RPC.block_info node b >>= fun bi ->
      match bi.protocol with
      | None -> raise Not_found
      | Some p -> RPC.Answer.return p in
    RPC.register1 dir
      Services.Blocks.protocol implementation in
  let dir =
    let implementation b () =
      Node.RPC.block_info node b >>= fun bi ->
      RPC.Answer.return bi.test_protocol in
    RPC.register1 dir
      Services.Blocks.test_protocol implementation in
  let dir =
    let implementation b () =
      Node.RPC.block_info node b >>= fun bi ->
      RPC.Answer.return bi.test_network in
    RPC.register1 dir
      Services.Blocks.test_network implementation in
  let dir =
    let implementation b () =
      Node.RPC.operations node b >>=
      RPC.Answer.return in
    RPC.register1 dir
      Services.Blocks.operations implementation in
  let dir =
    let implementation b () =
      Node.RPC.pending_operations node b >>= fun res ->
      RPC.Answer.return res in
    RPC.register1 dir
      Services.Blocks.pending_operations
      implementation in
  let dir =
    let implementation
        b { Services.Blocks.operations ; sort ; timestamp } =
      let timestamp =
        match timestamp with
        | None -> Time.now ()
        | Some x -> x in
      Node.RPC.preapply ~timestamp ~sort
        node b operations >>= function
      | Ok (fitness, operations) ->
          RPC.Answer.return
            (Ok { Services.Blocks.fitness ; operations ; timestamp })
      | Error _ as err -> RPC.Answer.return err in
    RPC.register1 dir
      Services.Blocks.preapply implementation in
  dir

let ops_dir _node =
  let ops_dir = RPC.empty in
  ops_dir

let rec insert_future_block (bi: Services.Blocks.block_info) = function
  | [] -> [bi]
  | ({timestamp} as head: Services.Blocks.block_info) :: tail as all ->
      if Time.compare bi.timestamp timestamp < 0 then
        bi :: all
      else
        head :: insert_future_block bi tail

let create_delayed_stream
    ~filtering ~include_ops requested_heads bi_stream delay =
  let stream, push = Lwt_stream.create  () in
  let current_blocks =
    ref (List.fold_left
           (fun acc h -> Block_hash_set.add h acc)
           Block_hash_set.empty requested_heads) in
  let next_future_block, is_futur_block,
      insert_future_block, pop_future_block =
    let future_blocks = ref [] in (* FIXME *)
    let future_blocks_set = ref Block_hash_set.empty in
    let next () =
      match !future_blocks with
      | [] -> None
      | bi :: _ -> Some bi
    and mem hash = Block_hash_set.mem hash !future_blocks_set
    and insert bi =
      future_blocks := insert_future_block bi !future_blocks ;
      future_blocks_set :=
        Block_hash_set.add bi.hash !future_blocks_set
    and pop time =
      match !future_blocks with
      | {timestamp} as bi :: rest when Time.(timestamp <= time) ->
          future_blocks := rest ;
          future_blocks_set :=
            Block_hash_set.remove bi.hash !future_blocks_set ;
        Some bi
      | _ -> None in
    next, mem, insert, pop in
  let _block_watcher_worker =
    let never_ending = fst (Lwt.wait ()) in
    let rec worker_loop () =
      lwt_debug "WWW worker_loop" >>= fun () ->
      let time = Time.(add (now ()) (Int64.of_int ~-delay)) in
      let migration_delay =
        match next_future_block () with
        | None -> never_ending
        | Some bi ->
            let delay = Time.diff bi.timestamp time in
            if delay <= 0L then
              Lwt.return_unit
            else
              Lwt_unix.sleep (Int64.to_float delay) in
      Lwt.choose [(migration_delay >|= fun () -> `Migrate) ;
                  (Lwt_stream.get bi_stream >|= fun x -> `Block x) ]
      >>= function
      | `Block None ->
          lwt_debug "WWW worker_loop None" >>= fun () ->
          Lwt.return_unit
      | `Block (Some (bi : Services.Blocks.block_info)) ->
          lwt_debug "WWW worker_loop Some" >>= fun () ->
          begin
            if not filtering
            || Block_hash_set.mem bi.predecessor !current_blocks
            || is_futur_block bi.predecessor
            then begin
              let time = Time.(add (now ()) (Int64.of_int ~-delay)) in
              if Time.(time < bi.timestamp) then begin
                insert_future_block bi ;
                Lwt.return_unit
              end else begin
                current_blocks :=
                  Block_hash_set.remove bi.predecessor !current_blocks
                  |> Block_hash_set.add bi.hash ;
                push (Some [[filter_bi include_ops bi]]) ;
                Lwt.return_unit
              end
            end else begin
              Lwt.return_unit
            end
          end >>= fun () ->
          worker_loop ()
      | `Migrate ->
          lwt_debug "WWW worker_loop Migrate" >>= fun () ->
          let time = Time.(add (now ()) (Int64.of_int ~-delay)) in
          let rec migrate_future_blocks () =
            match pop_future_block time with
            | Some bi ->
                push (Some [[filter_bi include_ops bi]]) ;
                migrate_future_blocks ()
            | None -> Lwt.return_unit in
          migrate_future_blocks () >>= fun () ->
          worker_loop ()
    in
    Lwt_utils.worker "block_watcher"
      ~run:worker_loop ~cancel:(fun () -> Lwt.return_unit) in
  stream

let list_blocks
    node
    { Services.Blocks.operations ; length ; heads ; monitor ; delay ;
      min_date; min_heads} =
  let include_ops = match operations with None -> false | Some x -> x in
  let len = match length with None -> 1 | Some x -> x in
  let monitor = match monitor with None -> false | Some x -> x in

  let time =
    match delay with
    | None -> None
    | Some delay -> Some (Time.(add (now ()) (Int64.of_int ~-delay))) in
  begin
    match heads with
    | None ->
        Node.RPC.heads node >>= fun heads ->
        let heads = List.map snd (Block_hash_map.bindings heads) in
        let heads =
          match min_date with
          | None -> heads
          | Some date ->
              let min_heads =
                match min_heads with
                | None -> 0
                | Some min_heads -> min_heads in
              snd @@
              List.fold_left (fun (min_heads, acc) (bi : Node.RPC.block_info) ->
                  min_heads - 1,
                  if Time.(>) bi.timestamp date || min_heads > 0 then bi :: acc
                  else acc)
                (min_heads, []) heads in
        begin
          match time with
          | None -> Lwt.return heads
          | Some time ->
              let rec current_predecessor (bi: Node.RPC.block_info)  =
                if Time.compare bi.timestamp time <= 0
                   || bi.hash = bi.predecessor then
                  Lwt.return bi
                else
                  Node.RPC.raw_block_info node bi.predecessor >>=
                  current_predecessor in
              Lwt_list.map_p current_predecessor heads
        end >|= fun heads_info ->
        let sorted_infos =
          List.sort
            (fun
              (bi1: Services.Blocks.block_info)
              (bi2: Services.Blocks.block_info) ->
               ~- (Fitness.compare bi1.fitness bi2.fitness))
            heads_info in
        List.map
          (fun ({ hash } : Services.Blocks.block_info) -> hash)
          sorted_infos
    | Some heads ->
        let known_block h =
          try ignore (Node.RPC.raw_block_info node h) ; true
          with Not_found -> false in
        Lwt.return (List.filter known_block heads)
  end >>= fun requested_heads ->
  Node.RPC.list node len requested_heads >>= fun requested_blocks ->
  if not monitor then
    let infos =
      List.map
        (List.map (filter_bi include_ops))
        requested_blocks in
    RPC.Answer.return infos
  else begin
    Node.RPC.valid_block_watcher node >>= fun (bi_stream, shutdown) ->
    let stream, shutdown =
      match delay with
      | None ->
          Lwt_stream.map (fun bi -> [[filter_bi include_ops bi]]) bi_stream,
          shutdown
      | Some delay ->
          let filtering = heads <> None in
          create_delayed_stream
            ~filtering ~include_ops requested_heads bi_stream delay,
          shutdown
    in
    let first_request = ref true in
    let next () =
      if not !first_request then begin
        Lwt_stream.get stream
      end else begin
        first_request := false ;
        let infos =
          List.map (List.map (filter_bi include_ops)) requested_blocks in
        Lwt.return (Some infos)
      end in
    RPC.Answer.return_stream { next ; shutdown }
  end

let list_operations node {Services.Operations.monitor; contents} =
  let monitor = match monitor with None -> false | Some x -> x in
  let include_ops = match contents with None -> false | Some x -> x in
  Node.RPC.operations node `Prevalidation >>= fun operations ->
  Lwt_list.map_p
    (fun hash ->
       if include_ops then
         Node.RPC.operation_content node hash >>= function
         | None | Some { Time.data = Error _ } -> Lwt.return (hash, None)
         | Some { Time.data = Ok bytes }->
             Lwt.return (hash, Some bytes)
       else
         Lwt.return (hash, None))
    operations >>= fun operations ->
  if not monitor then
    RPC.Answer.return operations
  else
    let stream, shutdown = Node.RPC.operation_watcher node in
    let first_request = ref true in
    let next () =
      if not !first_request then
        Lwt_stream.get stream >>= function
        | None -> Lwt.return_none
        | Some (h, op) when include_ops -> Lwt.return (Some [h, Some op])
        | Some (h, _) -> Lwt.return (Some [h, None])
      else begin
        first_request := false ;
        Lwt.return (Some operations)
      end in
    RPC.Answer.return_stream { next ; shutdown }

let get_operations node hash () =
  Node.RPC.operation_content node hash >>= function
  | Some bytes -> RPC.Answer.return bytes
  | None -> raise Not_found

let list_protocols node {Services.Protocols.monitor; contents} =
  let monitor = match monitor with None -> false | Some x -> x in
  let include_contents = match contents with None -> false | Some x -> x in
  Node.RPC.protocols node >>= fun protocols ->
  Lwt_list.map_p
    (fun hash ->
       if include_contents then
         Node.RPC.protocol_content node hash >>= function
         | None | Some { Time.data = Error _ } -> Lwt.return (hash, None)
         | Some { Time.data = Ok bytes }->
             Lwt.return (hash, Some bytes)
       else
         Lwt.return (hash, None))
    protocols >>= fun protocols ->
  if not monitor then
    RPC.Answer.return protocols
  else
    let stream, shutdown = Node.RPC.protocol_watcher node in
    let first_request = ref true in
    let next () =
      if not !first_request then
        Lwt_stream.get stream >>= function
        | None -> Lwt.return_none
        | Some (h, op) when include_contents -> Lwt.return (Some [h, Some op])
        | Some (h, _) -> Lwt.return (Some [h, None])
      else begin
        first_request := false ;
        Lwt.return (Some protocols)
      end in
    RPC.Answer.return_stream { next ; shutdown }

let get_protocols node hash () =
  Node.RPC.protocol_content node hash >>= function
  | Some bytes -> RPC.Answer.return bytes
  | None -> raise Not_found

let build_rpc_directory node =
  let dir = RPC.empty in
  let dir = RPC.register0 dir Services.Blocks.list (list_blocks node) in
  let dir = register_bi_dir node dir in
  let dir =
    let implementation block =
      Lwt.catch (fun () ->
          Node.RPC.context_dir node block >>= function
          | None -> Lwt.fail Not_found
          | Some context_dir -> Lwt.return context_dir)
        (fun _ -> Lwt.return RPC.empty) in
    RPC.register_dynamic_directory1
      ~descr:
        "All the RPCs which are specific to the protocol version."
      dir Services.Blocks.proto_path implementation in
  let dir =
    RPC.register0 dir Services.Operations.list (list_operations node) in
  let dir =
    RPC.register1 dir Services.Operations.bytes (get_operations node) in
  let dir =
    RPC.register0 dir Services.Protocols.list (list_protocols node) in
  let dir =
    RPC.register1 dir Services.Protocols.bytes (get_protocols node) in
  let dir =
    let implementation (net_id, pred, time, fitness, operations, header) =
      Node.RPC.block_info node (`Head 0) >>= fun bi ->
      let timestamp = Utils.unopt ~default:(Time.now ()) time in
      let net_id = Utils.unopt ~default:bi.net net_id in
      let predecessor = Utils.unopt ~default:bi.hash pred in
      let res =
        Store.Block.to_bytes {
          shell = { net_id ; predecessor ; timestamp ; fitness ; operations } ;
          proto = header ;
        } in
      RPC.Answer.return res in
    RPC.register0 dir Services.forge_block implementation in
  let dir =
    let implementation (net_id, block_hash) =
      Node.RPC.validate node net_id block_hash >>= fun res ->
      RPC.Answer.return res in
    RPC.register0 dir Services.validate_block implementation in
  let dir =
    let implementation (block, blocking, force) =
      Node.RPC.inject_block node ?force block >>= fun (hash, wait) ->
      begin
        (if blocking then wait else return ()) >>=? fun () -> return hash
      end >>= RPC.Answer.return in
    RPC.register0 dir Services.inject_block implementation in
  let dir =
    let implementation (contents, blocking, force) =
      Node.RPC.inject_operation node ?force contents >>= fun (hash, wait) ->
      begin
        (if blocking then wait else return ()) >>=? fun () -> return hash
      end >>= RPC.Answer.return in
    RPC.register0 dir Services.inject_operation implementation in
  let dir =
    let implementation (proto, blocking, force) =
      Node.RPC.inject_protocol ?force node proto >>= fun (hash, wait) ->
      begin
        (if blocking then wait else return ()) >>=? fun () -> return hash
      end >>= RPC.Answer.return in
    RPC.register0 dir Services.inject_protocol implementation in
  let dir =
    let implementation () =
      RPC.Answer.return Data_encoding.Json.(schema (Error_monad.error_encoding ())) in
    RPC.register0 dir Services.Error.service implementation in
  let dir =
    RPC.register1 dir Services.complete
      (fun s () ->
         Node.RPC.complete node s >>= RPC.Answer.return) in
  let dir =
    RPC.register2 dir Services.Blocks.complete
      (fun block s () ->
         Node.RPC.complete node ~block s >>= RPC.Answer.return) in
  let dir =
    RPC.register_describe_directory_service dir Services.describe in
  dir

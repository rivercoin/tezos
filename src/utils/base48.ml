(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Utils

let (>>=) = Lwt.bind
let (>|=) = Lwt.(>|=)

let decode_alphabet alphabet =
  let str = Bytes.make 256 '\255' in
  for i = 0 to String.length alphabet - 1 do
    Bytes.set str (int_of_char alphabet.[i]) (char_of_int i) ;
  done ;
  Bytes.to_string str

let default_alphabet =
  "eE2NXaQvHPqDdTJxfF36jb7VRmp9tAyMgG4L5cS8CKrnksBh"

let default_decode_alphabet = decode_alphabet default_alphabet

let count_trailing_char s c =
  let len = String.length s in
  let rec loop i =
    if i < 0 then len
    else if String.get s i <> c then (len-i-1)
    else loop (i-1) in
  loop (len-1)

let of_char ?(alphabet=default_decode_alphabet) x =
  let pos = String.get alphabet (int_of_char x) in
  if pos = '\255' then failwith "Invalid data" ;
  int_of_char pos

let to_char ?(alphabet=default_alphabet) x =
  alphabet.[x]

let forty_eight = Z.of_int 48

let raw_encode ?alphabet s =
  let zero, alphabet =
    match alphabet with
    | None -> default_alphabet.[0], default_alphabet
    | Some alphabet ->
        if String.length alphabet <> 48 then invalid_arg "Base48.encode" ;
        alphabet.[0], decode_alphabet alphabet in
  let zeros = count_trailing_char s '\000' in
  let len = String.length s in
  let res_len = (len * 8 + 4) / 5 in
  let res = Bytes.make res_len '\000' in
  let s = Z.of_bits s in
  let rec loop s i =
    if s = Z.zero then i else
    let s, r = Z.div_rem s forty_eight in
    Bytes.set res i (to_char ~alphabet (Z.to_int r));
    loop s (i+1) in
  let i = loop s 0 in
  let res = Bytes.sub_string res 0 i in
  res ^ String.make zeros zero

let raw_decode ?alphabet s =
  let zero, alphabet =
    match alphabet with
    | None -> default_alphabet.[0], default_decode_alphabet
    | Some alphabet ->
        if String.length alphabet <> 48 then invalid_arg "Base48.decode" ;
        alphabet.[0], decode_alphabet alphabet in
  let zeros = count_trailing_char s zero in
  let len = String.length s in
  let rec loop res i =
    if i < 0 then res else
    let x = Z.of_int (of_char ~alphabet (String.get s i)) in
    let res = Z.(add x (mul res forty_eight)) in
    loop res (i-1)
  in
  let res = Z.to_bits @@ loop Z.zero (len - zeros - 1) in
  let res_tzeros = count_trailing_char res '\000' in
  String.sub res 0 (String.length res - res_tzeros) ^
  String.make zeros '\000'

let checksum s =
  let bytes = Bytes.of_string s in
  let hash =
    let open Sodium.Generichash in
    let state = init ~size:32 () in
    Bytes.update state bytes ;
    Bytes.of_hash (final state) in
  Bytes.sub_string hash 0 4

(* Prepend a 4 bytes cryptographic checksum before encoding string s *)
let safe_encode ?alphabet s =
  raw_encode ?alphabet (s ^ checksum s)

let safe_decode ?alphabet s =
  let s = raw_decode ?alphabet s in
  let len = String.length s in
  let msg = String.sub s 0 (len-4)
  and msg_hash = String.sub s (len-4) 4 in
  if msg_hash <> checksum msg then
    invalid_arg "safe_decode" ;
  msg

type data = ..

type 'a encoding = {
  prefix: string;
  to_raw: 'a -> string ;
  of_raw: string -> 'a option ;
  wrap: 'a -> data ;
}

let simple_decode ?alphabet { prefix ; of_raw } s =
  safe_decode ?alphabet s |>
  remove_prefix ~prefix |>
  Utils.apply_option ~f:of_raw

let simple_encode ?alphabet { prefix ; to_raw } d =
  safe_encode ?alphabet (prefix ^ to_raw d)

type registred_encoding = Encoding : 'a encoding -> registred_encoding

module MakeEncodings(E: sig
    val encodings: registred_encoding list
  end) = struct

  let encodings = ref E.encodings

  let ambiguous_prefix prefix encodings =
    List.exists (fun (Encoding { prefix = s }) ->
        remove_prefix s prefix <> None ||
        remove_prefix prefix s <> None)
      encodings

  let register_encoding ~prefix ~to_raw ~of_raw ~wrap =
    if ambiguous_prefix prefix !encodings then
      Format.ksprintf invalid_arg
        "Base48.register_encoding: duplicate prefix: %S" prefix ;
    let encoding = { prefix ; to_raw ; of_raw ; wrap } in
    encodings := Encoding encoding :: !encodings ;
    encoding

  let decode ?alphabet s =
    let rec find s = function
      | [] -> None
      | Encoding { prefix ; of_raw ; wrap } :: encodings ->
          match remove_prefix ~prefix s with
          | None -> find s encodings
          | Some msg -> of_raw msg |> Utils.map_option ~f:wrap in
    let s = safe_decode ?alphabet s in
    find s !encodings

end

type 'a resolver =
    Resolver : {
      encoding: 'h encoding ;
      resolver: 'a -> string -> 'h list Lwt.t ;
    } -> 'a resolver

module MakeResolvers(R: sig
    type context
    val encodings: registred_encoding list ref
  end) = struct

  let resolvers = ref []

  let register_resolver
      (type a)
      (encoding : a encoding)
      (resolver : R.context -> string -> a list Lwt.t) =
    try
      resolvers := Resolver { encoding ; resolver } :: !resolvers
    with Not_found ->
      invalid_arg "Base48.register_resolver: unregistred encodings"

  type context = R.context

  let complete ?alphabet context request =
    (* One may extract from the prefix of a Base48-encoded value, a
       prefix of the original encoded value. Given that `48 = 3 * 2^4`,
       every "digits" in the Base48-prefix (i.e. a "bytes" in its ascii
       representation), provides for sure 4 bits of the original data.
       Hence, when we decode a prefix of a Base48-encoded value of
       length `n`, the `n/2` first bytes of the decoded value are (for
       sure) a prefix of the original value. *)
    let n = String.length request in
    let s = raw_decode request ?alphabet in
    let partial = String.sub s 0 (n / 2) in
    let rec find s = function
      | [] -> Lwt.return_nil
      | Resolver { encoding ; resolver } :: resolvers ->
          match remove_prefix ~prefix:encoding.prefix s with
          | None -> find s resolvers
          | Some msg ->
              resolver context msg >|= fun msgs ->
              filter_map
                (fun msg ->
                   let res = simple_encode encoding ?alphabet msg in
                   Utils.remove_prefix ~prefix:request res |>
                   Utils.map_option ~f:(fun _ -> res))
                msgs in
    find partial !resolvers

end

include MakeEncodings(struct let encodings = [] end)
include MakeResolvers(struct
    type context = unit
    let encodings = encodings
  end)

let register_resolver enc f = register_resolver enc (fun () s -> f s)
let complete ?alphabet s = complete ?alphabet () s

module Make(C: sig type context end) = struct
  include MakeEncodings(struct let encodings = !encodings end)
  include MakeResolvers(struct
      type context = C.context
      let encodings = encodings
    end)
end

module Prefix = struct
  let block_hash = "\000"
  let operation_hash = "\001"
  let protocol_hash = "\002"
  let ed25519_public_key_hash = "\003"
  let cryptobox_public_key_hash = "\004"
  let ed25519_public_key = "\012"
  let ed25519_secret_key = "\013"
  let ed25519_signature = "\014"
  let protocol_prefix = "\015"
end

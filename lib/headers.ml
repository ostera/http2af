type name = string
type value = string

type header = Hpack.header =
  { name : name
  ; value : value
  ; sensitive : bool
  }

type t = header list

let empty : t = []

let of_rev_list hs =
  List.map (fun (name, value) ->
    { name
    ; value
    ; sensitive = false
    })
  hs
let of_list t = of_rev_list (List.rev t)
let to_rev_list t = List.map (fun { name; value; _ } -> name, value) t
let to_list t = List.rev (to_rev_list t)
let to_hpack_list t = List.rev t

exception Local

module CI = struct
  let char_is_upper c = c >= 0x41 && c <= 0x5a
  let lower c =
    if char_is_upper c then c + 32 else c

  let equal x y =
    let len = String.length x in
    len = String.length y &&
    match for i = 0 to len - 1 do
      let c1 = Char.code (String.unsafe_get x i) in
      let c2 = Char.code (String.unsafe_get y i) in
      if c1 = c2
      then ()
      else if lower c1 <> lower c2 then raise Local
    done with
    | () -> true
    | exception Local -> false

  let is_lowercase x =
    let len = String.length x in
    match for i = 0 to len - 1 do
      let c1 = Char.code (String.unsafe_get x i) in
      if char_is_upper c1 then
        raise Local
      else
        ()
    done with
    | () -> true
    | exception Local -> false

end

let rec mem t name =
  match t with
  | {name = name'; _}::t' -> CI.equal name name' || mem t' name
  | _             -> false

(* TODO: do we need to keep a list of never indexed fields? *)
let add t ?(sensitive=false) name value =
  { name; value; sensitive }::t

let add_list t ls = (of_rev_list ls) @ t (* XXX(seliopou): do better here *)

let add_multi =
  let rec loop_outer t lss =
    match lss with
    | [] -> t
    | (n,vs)::lss' -> loop_inner t n vs lss'
  and loop_inner t n vs lss =
    match vs with
    | []     -> loop_outer t lss
    | v::vs' -> loop_inner ({ name = n; value = v; sensitive = false }::t) n vs' lss
  in
  loop_outer

let add_unless_exists t ?(sensitive=false) name value =
  if mem t name then
    t
  else
    { name; value; sensitive }::t

let replace t ?(sensitive=false) name value =
  let rec loop t n nv seen =
    match t with
    | [] ->
      if not seen then raise Local else []
    | ({ name = n'; _ } as nv')::t ->
      if CI.equal n n'
      then if seen
        then loop t n nv true
        else nv::loop t n nv true
      else nv'::loop t n nv false
  in
  try loop t name { name; value; sensitive } false
  with Local -> t

let remove t name =
  let rec loop s n seen =
    match s with
    | [] ->
      if not seen then raise Local else []
    | ({ name = n'; _ } as nv')::s' ->
      if CI.equal n n' then loop s' n true else nv'::(loop s' n false)
  in
  try loop t name false
  with Local -> t

let get t name =
  let rec loop t n =
    match t with
    | [] -> None
    | { name = n'; value; _ }::t' -> if CI.equal n n' then Some value else loop t' n
  in
  loop t name

let get_exn t name =
  let rec loop t =
    match t with
    | [] -> failwith (Printf.sprintf "Headers.get_exn: %S not found" name)
    | { name = n; value; _ }::t' -> if CI.equal name n then value else loop t'
  in
  loop t

let get_pseudo t name =
  get t (":" ^ name)

let get_pseudo_exn t name =
  get_exn t (":" ^ name)

let get_multi t name =
  let rec loop t acc =
    match t with
    | [] -> acc
    | { name = n; value ; _}::t' ->
      if CI.equal name n
      then loop t' (value::acc)
      else loop t' acc
  in
  loop t []

let get_multi_pseudo t name =
  get_multi t (":" ^ name)

module Pseudo = struct
  let reserved_request =
    [ ":method"
    ; ":scheme"
    ; ":authority"
    ; ":path"
    ]

  let reserved_response = [ ":status" ]

  (* 0x3A is the char code for `:` *)
  let is_pseudo name = Char.code (String.unsafe_get name 0) == 0x3A
end

let iter ~f t =
  List.iter (fun { name; value; _ } -> f name value) t

let fold ~f ~init t =
  List.fold_left (fun acc { name; value; _ } -> f name value acc) init t

let exists ~f t =
  List.exists (fun { name; value; _ } -> f name value) t

let to_string t =
  let b = Buffer.create 128 in
  List.iter (fun (name, value) ->
    Buffer.add_string b name;
    Buffer.add_string b ": ";
    Buffer.add_string b value;
    Buffer.add_string b "\r\n")
    (to_list t);
  Buffer.add_string b "\r\n";
  Buffer.contents b

let valid_request_headers t =
  let pseudo_ended = ref false in
  let invalid = exists ~f:(fun name _ ->
    let is_pseudo = Pseudo.is_pseudo name in
    let pseudo_did_end = !pseudo_ended in
    if not is_pseudo && not pseudo_did_end then
      pseudo_ended := true;
    (* From RFC7540§8.1.2:
         [...] header field names MUST be converted to lowercase
         prior to their encoding in HTTP/2. A request or response
         containing uppercase header field names MUST be treated as
         malformed (Section 8.1.2.6). *)
    not CI.(is_lowercase name) ||
    (* From RFC7540§8.1.2.1:
         Pseudo-header fields are only valid in the context in
         which they are defined. [...] pseudo-header fields defined
         for responses MUST NOT appear in requests. [...] Endpoints
         MUST treat a request or response that contains undefined
         or invalid pseudo-header fields as malformed (Section
         8.1.2.6). *)
    (is_pseudo && not (List.mem name Pseudo.reserved_request)) ||
    (* From RFC7540§8.1.2.1:
         All pseudo-header fields MUST appear in the header block before
         regular header fields. Any request or response that contains a
         pseudo-header field that appears in a header block after a regular
         header field MUST be treated as malformed (Section 8.1.2.6). *)
    (is_pseudo && pseudo_did_end))
    (to_hpack_list t)
  in
  not invalid

let trailers_valid t =
  let invalid = exists ~f:(fun name _ ->
    (* From RFC7540§8.1.2:
         [...] header field names MUST be converted to lowercase prior to
         their encoding in HTTP/2. A request or response containing
         uppercase header field names MUST be treated as malformed
         (Section 8.1.2.6). *)
    not (CI.is_lowercase name) ||
    (* From RFC7540§8.1.2.1:
         Pseudo-header fields MUST NOT appear in trailers.  Endpoints MUST
         treat a request or response that contains undefined or invalid
         pseudo-header fields as malformed (Section 8.1.2.6). *)
    Pseudo.is_pseudo name)
    t
  in
  not invalid

let pp_hum fmt t =
  let pp_elem fmt (name, value) = Format.fprintf fmt "@[(%S %S)@]" name value in
  Format.fprintf fmt "@[(";
  Format.pp_print_list pp_elem fmt (to_list t);
  Format.fprintf fmt ")@]";

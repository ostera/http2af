open Types

module IntSet = Set.Make (struct
  type t = int
  let compare = compare
end)

module HeaderFieldsTbl = struct
  include Hashtbl.Make (struct
    type t = string
    let equal = String.equal
    let hash s = Hashtbl.hash s
  end)

  let[@inline] find_opt h key =
    try Some (find h key)
    with Not_found -> None
end

module ValueMap = struct
  include Map.Make (String)

  let[@inline] find_opt k m =
    try Some (find k m)
    with Not_found -> None
end

type t =
  { table : Dynamic_table.t
    (* We maintain a lookup table of header fields to their indexes in the
     * dynamic table. The format is name -> (value -> index) *)
  ; lookup_table : int ValueMap.t HeaderFieldsTbl.t
  ; mutable next_seq : int
  }

module BinaryFormat = struct
  (* From RFC7541§6.2.3. Literal Header Field Never Indexed
       A literal header field never-indexed representation starts with the
       '0001' 4-bit pattern. *)
  let never_indexed = 0b00010000, 4

  (* From RFC7541§6.2.2: Literal Header Field without Indexing
       A literal header field without indexing representation starts with the
       '0000' 4-bit pattern. *)
  let without_indexing = 0b00000000, 4

  (* From RFC7541§6.2.1: Literal Header Field with Incremental Indexing
       A literal header field with incremental indexing representation starts
       with the '01' 2-bit pattern. *)
  let incremental_indexing = 0b01000000, 6

  (* From RFC7541§6.1: Indexed Header Field Representation
       An indexed header field starts with the '1' 1-bit pattern, followed by
       the index of the matching header field, represented as an integer with
       a 7-bit prefix (see Section 5.1). *)
  let indexed = 0b10000000, 7

  let[@inline] is_indexed = function
    | 128 -> true
    | _ -> false
end

let on_evict lookup_table = fun (name, value) ->
  let map = HeaderFieldsTbl.find lookup_table name in
  if ValueMap.cardinal map = 1 then
    HeaderFieldsTbl.remove lookup_table name
  else
    let map = ValueMap.remove value map in
    HeaderFieldsTbl.replace lookup_table name map

let create capacity =
  let lookup_table = HeaderFieldsTbl.create capacity in
  { table = Dynamic_table.create ~on_evict:(on_evict lookup_table) capacity
  ; lookup_table
  ; next_seq = 0
  }

let add ({table; lookup_table; next_seq} as encoder) entry =
  let name, value = entry in
  Dynamic_table.add table entry;
  let map = match HeaderFieldsTbl.find_opt lookup_table name with
  | Some map -> ValueMap.add value next_seq map
  | None -> ValueMap.singleton value next_seq
  in
  encoder.next_seq <- next_seq + 1;
  HeaderFieldsTbl.replace lookup_table name map

let[@inline] find_token encoder without_indexing token name value =
  let rec loop i =
    let (name', value') = Static_table.table.(i) in
    if name' = name then begin
      if value' = value then
        (* From RFC7541§6.1: Indexed Header Field Representation
             An indexed header field starts with the '1' 1-bit pattern,
             followed by the index of the matching header field. *)
        BinaryFormat.indexed, (i + 1)
      else
        (* Advance one token in the static table, as the next entry might have
         * a value that can fall into the above branch. We're guaranteed to
         * always get the first token (index) in the static table for `name`,
         * because that's what `Static_table.lookup_token` returns. *)
        loop (i + 1)
    end else begin
      (* This is a header field whose value we didn't find in the static table
       * after looping. We ended here (name <> name') because we looped to
       * check whether the value was indexed in the static table. We can still
       * use the token index to encode the header name. *)
      let index = token + 1 in
      if without_indexing then
        (* From RFC7541§6.2.2: Literal Header Field without Indexing
             If the header field name matches the header field name of an entry
             stored in the static table or the dynamic table, the header field
             name can be represented using the index of that entry. *)
        BinaryFormat.without_indexing, index
      else begin
        (* From RFC7541§6.2.1: Literal Header Field with Incremental Indexing
             A literal header field with incremental indexing representation
             results in appending a header field to the decoded header list and
             inserting it as a new entry into the dynamic table. *)
        add encoder (name, value);
        BinaryFormat.incremental_indexing, index
      end
    end
  in
  loop token

let[@inline] seq_to_index next_seq seq =
  Static_table.table_size + next_seq - seq

let tokens_without_indexing =
  (* From RFC7541§6.2.2: Never-Indexed Literals
       Either form of header field name representation is followed by the
       header field value represented as a string literal (see Section 5.2).

     Note: we choose not to index the values of these fields as they would
     vary immensely. This way, we save some additions / evictions from the
     dynamic table. *)
  IntSet.of_list Static_table.TokenIndices.[
      path;
      age;
      content_length;
      etag;
      if_modified_since;
      if_none_match;
      location;
      set_cookie;
    ]

let[@inline] is_without_indexing token =
  token <> -1 && IntSet.mem token tokens_without_indexing

let[@inline] is_sensitive token value =
  token <> -1 &&
  (* From RFC7541§7.1.3: Never-Indexed Literals
       An encoder might also choose not to index values for header fields that
       are considered to be highly valuable or sensitive to recovery, such as
       the Cookie or Authorization header fields. *)
  Static_table.TokenIndices.(token == authorization ||
   (token == cookie && String.length value < 20))

let encode ({lookup_table; next_seq; _} as encoder) {name; value; sensitive} =
  let token = Static_table.lookup_token_index name in
  let token_found_in_static_table = token <> -1 in
  if sensitive || is_sensitive token value then begin
    (* never indexed literal header field, find the index *)
    let index = if token_found_in_static_table then
      (* From RFC7541§6.2.2: Literal Header Field without Indexing
           If the header field name matches the header field name of an entry
           stored in the static table or the dynamic table, the header field
           name can be represented using the index of that entry. *)
      token + 1
    else match HeaderFieldsTbl.find_opt lookup_table name with
    | Some map ->
      let _, any_entry = ValueMap.choose map in
      seq_to_index next_seq any_entry
    | None ->
      (* From RFC7541§6.2.2: Literal Header Field without Indexing
           Otherwise, the header field name is represented as a string
           literal (see Section 5.2). A value 0 is used in place of the 4-bit
           index, followed by the header field name. *)
      0
    in
    BinaryFormat.never_indexed, index
  end else if token_found_in_static_table then begin
    (* Header name is represented in the static table. *)
    match HeaderFieldsTbl.find_opt lookup_table name with
    | Some map ->
      (* Header value is indexed in the dynamic table. *)
      begin match ValueMap.find_opt value map with
      | Some seq ->
        (* From RFC7541§6.1: Indexed Header Field Representation
             An indexed header field representation identifies an entry in
             either the static table or the dynamic table (see Section 2.3). *)
        BinaryFormat.indexed, (seq_to_index next_seq seq)
      | None ->
        (* Header value is not indexed in the dynamic table. Check if it's an
         * entry in the static table or if we need to encode its value, (and
         * potentially name if the field is requested to be encoded without
         * indexing). *)
        let without_indexing = is_without_indexing token in
        find_token encoder without_indexing token name value
      end
    | None ->
      let without_indexing = is_without_indexing token in
      find_token encoder without_indexing token name value
    end
  else
    match HeaderFieldsTbl.find_opt lookup_table name with
    | Some map ->
      begin match ValueMap.find_opt value map with
      | Some seq ->
        BinaryFormat.indexed, (seq_to_index next_seq seq)
      | None ->
        let index = seq_to_index next_seq (snd (ValueMap.choose map)) in
        if is_without_indexing token then
          BinaryFormat.without_indexing, index
        else begin
          (* From RFC7541§6.2.1
               A literal header field with incremental indexing representation
               results in appending a header field to the decoded header list
               and inserting it as a new entry into the dynamic table. *)
          add encoder (name, value);
          BinaryFormat.incremental_indexing, index
        end
      end
    | None ->
      if is_without_indexing token then
        BinaryFormat.without_indexing, 0
      else begin
        (* From RFC7541§6.2.1
             A literal header field with incremental indexing representation
             results in appending a header field to the decoded header list and
             inserting it as a new entry into the dynamic table. *)
        add encoder (name, value);
        BinaryFormat.incremental_indexing, 0
      end

let[@inline] encode_int t prefix n i =
  let max_prefix = 1 lsl n - 1 in
  if i < max_prefix then
    (* From RFC7541§5.1:
         If the integer value is small enough, i.e., strictly less than 2^N-1,
         it is encoded within the N-bit prefix. *)
    Faraday.write_uint8 t (prefix lor i)
  else begin
    (* From RFC7541§5.1:
         Otherwise, all the bits of the prefix are set to 1, and the value,
         decreased by 2^N-1, is encoded using a list of one or more octets. The
         most significant bit of each octet is used as a continuation flag: its
         value is set to 1 except for the last octet in the list. The remaining
         bits of the octets are used to encode the decreased value. *)
    let i = i - max_prefix in
    Faraday.write_uint8 t (prefix lor max_prefix);
    let rec loop i =
      if i >= 128 then begin
        Faraday.write_uint8 t ((i land 127) lor 128);
        loop (i lsr 7)
      end else
        Faraday.write_uint8 t i
    in
    loop i
  end

let[@inline] encode_string t s =
  let string_length = String.length s in
  let huffman_length = Huffman.encoded_length s in
  if huffman_length > string_length then begin
    (* From RFC7541§5.2:
         The number of octets used to encode the string literal, encoded as an
         integer with a 7-bit prefix (see Section 5.1). *)
    encode_int t 0 7 string_length;
    (* From RFC7541§5.2:
         The encoded data of the string literal. If H is '0', then the encoded
         data is the raw octets of the string literal. If H is '1', then the
         encoded data is the Huffman encoding of the string literal. *)
    Faraday.write_string t s
  end else begin
    (* From RFC7541§5.2:
         The number of octets used to encode the string literal, encoded as an
         integer with a 7-bit prefix (see Section 5.1). *)
    encode_int t 128 7 huffman_length;
    (* From RFC7541§5.2:
         The encoded data of the string literal. If H is '0', then the encoded
         data is the raw octets of the string literal. If H is '1', then the
         encoded data is the Huffman encoding of the string literal. *)
    Huffman.encode t s
  end

let encode_header encoder t ({ name; value; _ } as header) =
  let (prefix, prefix_length), index = encode encoder header in
  encode_int t prefix prefix_length index;
  if not (BinaryFormat.is_indexed prefix) then begin
    if index == 0 then begin
      (* From RFC7541§6.2.2: Literal Header Field without Indexing
           If the header field name matches the header field name of an entry
           stored in the static table or the dynamic table, the header field name
           can be represented using the index of that entry. In this case, the
           index of the entry is represented as an integer with a 4-bit prefix
           (see Section 5.1). This value is always non-zero.

           Otherwise, the header field name is represented as a string literal
           (see Section 5.2). A value 0 is used in place of the 4-bit index,
           followed by the header field name. *)
      encode_string t name;
    end;
    (* From RFC7541§6.2.2: Literal Header Field without Indexing
         Either form of header field name representation is followed by the
         header field value represented as a string literal (see Section 5.2). *)
    encode_string t value
  end

let set_capacity { table; _ } new_capacity =
  Dynamic_table.set_capacity table new_capacity

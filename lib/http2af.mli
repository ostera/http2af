(** Http2/af is a high-performance, memory-efficient, and scalable HTTP/2
    implementation for OCaml. It is based on the concepts in http/af, and
    therefore uses the Angstrom and Faraday libraries to implement the parsing
    and serialization layers of the HTTP/2 standard. It also preserves the same
    API as http/af wherever possible.

    Not unlike http/af, the user should be familiar with HTTP, and the basic
    principles of memory management and vectorized IO in order to use this
    library. *)

open Result

(** {2 Basic HTTP Types} *)


(** Request Method

    The request method token is the primary source of request semantics;
    it indicates the purpose for which the client has made this request
    and what is expected by the client as a successful result.

    See {{:https://tools.ietf.org/html/rfc7231#section-4} RFC7231§4} for more
    details.

    This module is a proxy to [Httpaf.Method] and is included in http2/af for
    convenience. *)
module Method : module type of Httpaf.Method


(** Response Status Codes

    The status-code element is a three-digit integer code giving the result of
    the attempt to understand and satisfy the request.

    See {{:https://tools.ietf.org/html/rfc7231#section-6} RFC7231§6} for more
    details.

    For the most part, this module is a proxy to [Httpaf.Status]. Its
    [informational] type, however, removes support for the
    [Switching_protocols] tag, as per the HTTP/2 spec (relevant portion
    reproduced below).

    From RFC7540§8.1.1:
      HTTP/2 removes support for the 101 (Switching Protocols) informational
      status code ([RFC7231], Section 6.2.2).

    See {{:https://tools.ietf.org/html/rfc7540#section-8.1.1} RFC7540§8.1.1}
    for more details. *)
module Status : sig
  type informational = [ | `Continue ]
  (** The 1xx (Informational) class of status code indicates an interim
      response for communicating connection status or request progress
      prior to completing the requested action and sending a final
      response.

      See {{:https://tools.ietf.org/html/rfc7231#section-6.2} RFC7231§6.2}
      for more details. *)

  type successful = Httpaf.Status.successful
  (** The 2xx (Successful) class of status code indicates that the client's
      request was successfully received, understood, and accepted.

      See {{:https://tools.ietf.org/html/rfc7231#section-6.3} RFC7231§6.3}
      for more details. *)

  type redirection = Httpaf.Status.redirection
  (** The 3xx (Redirection) class of status code indicates that further
      action needs to be taken by the user agent in order to fulfill the
      request.

      See {{:https://tools.ietf.org/html/rfc7231#section-6.4} RFC7231§6.4} for
      more details. *)

  type client_error = Httpaf.Status.client_error
  (** The 4xx (Client Error) class of status code indicates that the client
      seems to have erred.

      See {{:https://tools.ietf.org/html/rfc7231#section-6.5} RFC7231§6.5} for
      more details. *)

  type server_error = Httpaf.Status.server_error
  (** The 5xx (Server Error) class of status code indicates that the server is
      aware that it has erred or is incapable of performing the requested
      method.

      See {{:https://tools.ietf.org/html/rfc7231#section-6.6} RFC7231§6.6} for
      more details. *)

  type standard = [
    | informational
    | Httpaf.Status.successful
    | Httpaf.Status.redirection
    | Httpaf.Status.client_error
    | Httpaf.Status.server_error
    ]
  (** The status codes defined in the HTTP/1.1 RFCs, excluding the [Switching
      Protocols] status as per the HTTP/2 RFC. *)

  type t = [
    | standard
    | `Code of int ]
  (** The standard codes along with support for custom codes. *)

  val default_reason_phrase : standard -> string
  (** [default_reason_phrase standard] is the example reason phrase provided
      by RFC7231 for the [standard] status code. The RFC allows servers to use
      reason phrases besides these in responses. *)

  val to_code : t -> int
  (** [to_code t] is the integer representation of [t]. *)

  val of_code : int -> t
  (** [of_code i] is the [t] representation of [i]. [of_code] raises [Failure]
      if [i] is not a positive three-digit number. *)

  val unsafe_of_code : int -> t
  (** [unsafe_of_code i] is equivalent to [of_code i], except it accepts any
      positive code, regardless of the number of digits it has. On negative
      codes, it will still raise [Failure]. *)

  val is_informational : t -> bool
  (** [is_informational t] is [true] iff [t] belongs to the Informational class
      of status codes. *)

  val is_successful : t -> bool
  (** [is_successful t] is [true] iff [t] belongs to the Successful class of
      status codes. *)

  val is_redirection : t -> bool
  (** [is_redirection t] is [true] iff [t] belongs to the Redirection class of
      status codes. *)

  val is_client_error : t -> bool
  (** [is_client_error t] is [true] iff [t] belongs to the Client Error class
      of status codes. *)

  val is_server_error : t -> bool
  (** [is_server_error t] is [true] iff [t] belongs to the Server Error class
      of status codes. *)

  val is_error : t -> bool
  (** [is_server_error t] is [true] iff [t] belongs to the Client Error or
      Server Error class of status codes. *)

  val to_string : t -> string
  val of_string : string -> t

  val pp_hum : Format.formatter -> t -> unit
end


(** Header Fields

    Each header field consists of a lowercase {b field name} and a {b field
    value}. Per the HTTP/2 specification, header field names {b must} be
    converted to lowercase prior to their encoding in HTTP/2 (see
    {{:https://tools.ietf.org/html/rfc7540#section-8.1.2} RFC7540§8.1.2} for
    more details). http2/af does {b not} convert field names to lowercase; it
    is therefore the responsibility of the caller of the functions contained in
    this module to use lowercase names for header fields.

    The order in which header fields {i with differing field names}
    are received is not significant, except for pseudo-header fields, which
    {b must} appear in header blocks before regular fields (see
    {{:https://tools.ietf.org/html/rfc7540#section-8.1.2.1} RFC7540§8.1.2.1}
    for more details).

    A sender MUST NOT generate multiple header fields with the same field name
    in a message unless either the entire field value for that header field is
    defined as a comma-separated list or the header field is a well-known
    exception, e.g., [Set-Cookie].

    A recipient MAY combine multiple header fields with the same field name
    into one "field-name: field-value" pair, without changing the semantics of
    the message, by appending each subsequent field value to the combined field
    value in order, separated by a comma. {i The order in which header fields
    with the same field name are received is therefore significant to the
    interpretation of the combined field value}; a proxy MUST NOT change the
    order of these field values when forwarding a message.

    {i Note.} Unless otherwise specified, all operations preserve header field
    order and all reference to equality on names is assumed to be
    case-insensitive.

    See {{:https://tools.ietf.org/html/rfc7230#section-3.2} RFC7230§3.2} for
    more details. *)
module Headers : sig
  type t
  (** The type of a group of header fields. *)

  type name = string
  (** The type of a lowercase header name. *)

  type value = string
  (** The type of a header value. *)

  (** {3 Constructor} *)

  val empty : t
  (** [empty] is the empty collection of header fields. *)

  val of_list : (name * value) list -> t
  (** [of_list assoc] is a collection of header fields defined by the
      association list [assoc]. [of_list] assumes the order of header fields in
      [assoc] is the intended transmission order. The following equations
      should hold:

        {ul
        {- [to_list (of_list lst) = lst] }
        {- [get (of_list [("k", "v1"); ("k", "v2")]) "k" = Some "v2"]. }} *)

  val of_rev_list : (name * value) list -> t
  (** [of_list assoc] is a collection of header fields defined by the
      association list [assoc]. [of_list] assumes the order of header fields in
      [assoc] is the {i reverse} of the intended trasmission order. The
      following equations should hold:

        {ul
        {- [to_list (of_rev_list lst) = List.rev lst] }
        {- [get (of_rev_list [("k", "v1"); ("k", "v2")]) "k" = Some "v1"]. }} *)

  val to_list : t -> (name * value) list
  (** [to_list t] is the association list of header fields contained in [t] in
      transmission order. *)

  val to_rev_list : t -> (name * value) list
  (** [to_rev_list t] is the association list of header fields contained in [t]
      in {i reverse} transmission order. *)

  val add : t -> ?sensitive:bool -> name -> value -> t
  (** [add t ?sensitive name value] is a collection of header fields that is
      the same as [t] except with [(name, value)] added at the end of the
      trasmission order. Additionally, [sensitive] specifies whether this
      header field should not be compressed by HPACK and instead encoded as
      a never-indexed literal (see
      {{:https://tools.ietf.org/html/rfc7541#section-7.1.3} RFC7541§7.1.3} for
      more details).

      The following equations should hold:

        {ul
        {- [get (add t name value) name = Some value] }} *)

  val add_unless_exists : t -> ?sensitive:bool -> name -> value -> t
  (** [add_unless_exists t ?sensitive name value] is a collection of header
      fields that is the same as [t] if [t] already inclues [name], and
      otherwise is equivalent to [add t ?sensitive name value]. *)

  val add_list : t -> (name * value) list -> t
  (** [add_list t assoc] is a collection of header fields that is the same as
      [t] except with all the header fields in [assoc] added to the end of the
      transmission order, in reverse order. *)

  val add_multi : t -> (name * value list) list -> t
  (** [add_multi t assoc] is the same as

      {[
        add_list t (List.concat_map assoc ~f:(fun (name, values) ->
          List.map values ~f:(fun value -> (name, value))))
      ]}

      but is implemented more efficiently. For example,

      {[
        add_multi t ["name1", ["x", "y"]; "name2", ["p", "q"]]
          = add_list ["name1", "x"; "name1", "y"; "name2", "p"; "name2", "q"]
      ]} *)

  val remove : t -> name -> t
  (** [remove t name] is a collection of header fields that contains all the
      header fields of [t] except those that have a header-field name that are
      equal to [name]. If [t] contains multiple header fields whose name is
      [name], they will all be removed. *)

  val replace : t -> ?sensitive:bool -> name -> value -> t
  (** [replace t ?sensitive name value] is a collection of header fields that
      is the same as [t] except with all header fields with a name equal to
      [name] removed and replaced with a single header field whose name is
      [name] and whose value is [value]. This new header field will appear in
      the transmission order where the first occurrence of a header field with
      a name matching [name] was found.

      If no header field with a name equal to [name] is present in [t], then
      the result is simply [t], unchanged. *)

  (** {3 Destructors} *)

  val mem : t -> name -> bool
  (** [mem t name] is [true] iff [t] includes a header field with a name that
      is equal to [name]. *)

  val get : t -> name -> value option
  (** [get t name] returns the last header from [t] with name [name], or [None]
      if no such header is present. *)

  val get_exn : t -> name -> value
  (** [get t name] returns the last header from [t] with name [name], or raises
      if no such header is present. *)

  val get_multi : t -> name -> value list
  (** [get_multi t name] is the list of header values in [t] whose names are
      equal to [name]. The returned list is in transmission order. *)

  (** {3 Iteration} *)

  val iter : f:(name -> value -> unit) -> t -> unit
  val fold : f:(name -> value -> 'a -> 'a) -> init:'a -> t -> 'a

  (** {3 Utilities} *)

  val to_string : t -> string

  val pp_hum : Format.formatter -> t -> unit
end

(** {2 Message Body} *)

module Body : sig
  type 'rw t

  val schedule_read
    :  [`read] t
    -> on_eof  : (unit -> unit)
    -> on_read : (Bigstringaf.t -> off:int -> len:int -> unit)
    -> unit
  (** [schedule_read t ~on_eof ~on_read] will setup [on_read] and [on_eof] as
      callbacks for when bytes are available in [t] for the application to
      consume, or when the input channel has been closed and no further bytes
      will be received by the application.

      Once either of these callbacks have been called, they become inactive.
      The application is responsible for scheduling subsequent reads, either
      within the [on_read] callback or by some other mechanism. *)

  val write_char : [`write] t -> char -> unit
  (** [write_char w char] copies [char] into an internal buffer. If possible,
      this write will be combined with previous and/or subsequent writes before
      transmission. *)

  val write_string : [`write] t -> ?off:int -> ?len:int -> string -> unit
  (** [write_string w ?off ?len str] copies [str] into an internal buffer. If
      possible, this write will be combined with previous and/or subsequent
      writes before transmission. *)

  val write_bigstring : [`write] t -> ?off:int -> ?len:int -> Bigstringaf.t -> unit
  (** [write_bigstring w ?off ?len bs] copies [bs] into an internal buffer. If
      possible, this write will be combined with previous and/or subsequent
      writes before transmission. *)

  val schedule_bigstring : [`write] t -> ?off:int -> ?len:int -> Bigstringaf.t -> unit
  (** [schedule_bigstring w ?off ?len bs] schedules [bs] to be transmitted at
      the next opportunity without performing a copy. [bs] should not be
      modified until a subsequent call to {!flush} has successfully
      completed. *)

  val flush : [`write] t -> (unit -> unit) -> unit
  (** [flush t f] makes all bytes in [t] available for writing to the awaiting
      output channel. Once those bytes have reached that output channel, [f]
      will be called.

      The type of the output channel is runtime-dependent, as are guarantees
      about whether those packets have been queued for delivery or have
      actually been received by the intended recipient. *)

  val close_reader : [`read] t -> unit
  (** [close_reader t] closes [t], indicating that any subsequent input
      received should be discarded. *)

  val close_writer : [`write] t -> unit
  (** [close_writer t] closes [t], causing subsequent write calls to raise. If
      [t] is writable, this will cause any pending output to become available
      to the output channel. *)

  val is_closed : _ t -> bool
  (** [is_closed t] is [true] if {!close} has been called on [t] and [false]
      otherwise. A closed [t] may still have pending output. *)
end


(** {2 Message Types} *)

(** Request

    A client-initiated HTTP message. *)
module Request : sig
  type t =
    { meth    : Method.t
    ; target  : string
    ; headers : Headers.t }

  val create
    :  ?headers:Headers.t (** default is {!Headers.empty} *)
    -> Method.t
    -> string
    -> t

  val pp_hum : Format.formatter -> t -> unit
end


(** Response

    A server-generated message to a {!Request.t}. *)
module Response : sig
  type t =
    { status  : Status.t
    ; headers : Headers.t }

  val create
    :  ?headers:Headers.t (** default is {!Headers.empty} *)
    -> Status.t
    -> t
  (** [create ?headers status] creates an HTTP response with the given
      parameters. Unlike the [Response] type in http/af, http2/af does not
      define a way for responses to carry reason phrases or protocol version.

      See {{:https://tools.ietf.org/html/rfc7540#section-8.1.2.4}
      RFC7540§8.1.2.4} for more details. *)

  val pp_hum : Format.formatter -> t -> unit
end


(** IOVec *)
module IOVec : module type of Httpaf.IOVec

(** {2 Request Descriptor} *)
module Reqd : sig
  type t

  val request : t -> Request.t
  val request_body : t -> [`read] Body.t

  val response : t -> Response.t option
  val response_exn : t -> Response.t

  (** Responding

      The following functions will initiate a response for the corresponding
      request in [t]. When the response is fully transmitted to the wire, the
      stream completes.

      From {{:https://tools.ietf.org/html/rfc7540#section-8.1} RFC7540§8.1}:
        An HTTP request/response exchange fully consumes a single stream. *)

  val respond_with_string    : t -> Response.t -> string -> unit
  val respond_with_bigstring : t -> Response.t -> Bigstringaf.t -> unit
  val respond_with_streaming : ?flush_headers_immediately:bool -> t -> Response.t -> [`write] Body.t

  val push : t -> Request.t -> t
  (** Pushing

      HTTP/2 allows a server to pre-emptively send (or "push") responses (along
      with corresponding "promised" requests) to a client in association with a
      previous client-initiated request. This can be useful when the server
      knows the client will need to have those responses available in order to
      fully process the response to the original request.

      [push reqd request] creates a new (pushed) request descriptor that allows
      responding to the "promised" request. This function raises an exception
      if server push is not enabled for the connection.

      See {{:https://tools.ietf.org/html/rfc7540#section-8.2} RFC7540§8.2} for
      more details. *)

  (** {3 Exception Handling} *)

  val report_exn : t -> exn -> unit
  val try_with : t -> (unit -> unit) -> (unit, exn) result
end

(** {2 HTTP/2 Configuration} *)
module Config : sig
  type t =
    { read_buffer_size          : int
      (** [read_buffer_size] specifies the size of the largest frame payload
          that the sender is willing to receive, in octets. Defaults to
          [16384] *)
    ; request_body_buffer_size  : int  (** Defaults to [4096] *)
    ; response_buffer_size      : int  (** Defaults to [1024] *)
    ; response_body_buffer_size : int  (** Defaults to [4096] *)
    ; enable_server_push        : bool (** Defaults to [true] *)
    ; max_concurrent_streams    : int
      (** [max_concurrent_streams] specifies the maximum number of streams that
          the sender will allow the peer to initiate. Defaults to [1^31 - 1] *)
    ; initial_window_size       : int
      (** [initial_window_size] specifies the initial window size for flow
          control tokens. Defaults to [65535] *)
    }

  val default : t
  (** [default] is a configuration record with all parameters set to their
      default values. *)
end

(** {2 Server Connection} *)

module Server_connection : sig
  type t

  type error =
    [ `Bad_request | `Internal_server_error | `Exn of exn ]

  type request_handler = Reqd.t -> unit

  type error_handler =
    ?request:Request.t -> error -> (Headers.t -> [`write] Body.t) -> unit

  val create
    :  ?config:Config.t
    -> ?error_handler:error_handler
    -> request_handler
    -> t
  (** [create ?config ?error_handler ~request_handler] creates a connection
      handler that will service individual requests with [request_handler]. *)

  val next_read_operation : t -> [ `Read | `Yield | `Close ]
  (** [next_read_operation t] returns a value describing the next operation
      that the caller should conduct on behalf of the connection. *)

  val read : t -> Bigstringaf.t -> off:int -> len:int -> int
  (** [read t bigstring ~off ~len] reads bytes of input from the provided range
      of [bigstring] and returns the number of bytes consumed by the
      connection.  {!read} should be called after {!next_read_operation}
      returns a [`Read] value and additional input is available for the
      connection to consume. *)

  val read_eof : t -> Bigstringaf.t -> off:int -> len:int -> int
  (** [read t bigstring ~off ~len] reads bytes of input from the provided range
      of [bigstring] and returns the number of bytes consumed by the
      connection.  {!read} should be called after {!next_read_operation}
      returns a [`Read] and an EOF has been received from the communication
      channel. The connection will attempt to consume any buffered input and
      then shutdown the HTTP parser for the connection. *)

  val yield_reader : t -> (unit -> unit) -> unit
  (** [yield_reader t continue] registers with the connection to call
      [continue] when reading should resume. {!yield_reader} should be called
      after {!next_read_operation} returns a [`Yield] value. *)

  val next_write_operation : t -> [
    | `Write of Bigstringaf.t IOVec.t list
    | `Yield
    | `Close of int ]
  (** [next_write_operation t] returns a value describing the next operation
      that the caller should conduct on behalf of the connection. *)

  val report_write_result : t -> [`Ok of int | `Closed] -> unit
  (** [report_write_result t result] reports the result of the latest write
      attempt to the connection. {!report_write_result} should be called after
      a call to {!next_write_operation} that returns a [`Write buffer] value.

        {ul
        {- [`Ok n] indicates that the caller successfully wrote [n] bytes of
        output from the buffer that the caller was provided by
        {!next_write_operation}. }
        {- [`Closed] indicates that the output destination will no longer
        accept bytes from the write processor. }} *)

  val yield_writer : t -> (unit -> unit) -> unit
  (** [yield_writer t continue] registers with the connection to call
      [continue] when writing should resume. {!yield_writer} should be called
      after {!next_write_operation} returns a [`Yield] value. *)

  val report_exn : t -> exn -> unit
  (** [report_exn t exn] reports that an error [exn] has been caught and
      that it has been attributed to [t]. Calling this function will switch [t]
      into an error state. Depending on the state [t] is transitioning from, it
      may call its error handler before terminating the connection. *)

  val is_closed : t -> bool
  (** [is_closed t] is [true] if both the read and write processors have been
      shutdown. When this is the case {!next_read_operation} will return
      [`Close _] and {!next_write_operation} will do the same will return a
      [`Write _] until all buffered output has been flushed. *)

  (* val error_code : t -> error option *)
  (** [error_code t] returns the [error_code] that caused the connection to
      close, if one exists. *)

  (**/**)
  val shutdown : t -> unit
  (**/**)
end

(** {2 Client Connection} *)

(* module Client_connection : sig

  type t

  type error =
    [ `Malformed_response of string | `Invalid_response_body_length of Response.t | `Exn of exn ]

  type response_handler = Response.t -> [`read] Body.t  -> unit

  type error_handler = error -> unit

  val request
    :  ?config:Config.t
    -> Request.t
    -> error_handler:error_handler
    -> response_handler:response_handler
    -> [`write] Body.t * t

  val next_read_operation : t -> [ `Read | `Close ]
  (** [next_read_operation t] returns a value describing the next operation
      that the caller should conduct on behalf of the connection. *)

  val read : t -> Bigstringaf.t -> off:int -> len:int -> int
  (** [read t bigstring ~off ~len] reads bytes of input from the provided range
      of [bigstring] and returns the number of bytes consumed by the
      connection.  {!read} should be called after {!next_read_operation}
      returns a [`Read] value and additional input is available for the
      connection to consume. *)

  val read_eof : t -> Bigstringaf.t -> off:int -> len:int -> int
  (** [read t bigstring ~off ~len] reads bytes of input from the provided range
      of [bigstring] and returns the number of bytes consumed by the
      connection.  {!read} should be called after {!next_read_operation}
      returns a [`Read] and an EOF has been received from the communication
      channel. The connection will attempt to consume any buffered input and
      then shutdown the HTTP parser for the connection. *)

  val next_write_operation : t -> [
    | `Write of Bigstringaf.t IOVec.t list
    | `Yield
    | `Close of int ]
  (** [next_write_operation t] returns a value describing the next operation
      that the caller should conduct on behalf of the connection. *)

  val report_write_result : t -> [`Ok of int | `Closed] -> unit
  (** [report_write_result t result] reports the result of the latest write
      attempt to the connection. {!report_write_result} should be called after a
      call to {!next_write_operation} that returns a [`Write buffer] value.

        {ul
        {- [`Ok n] indicates that the caller successfully wrote [n] bytes of
        output from the buffer that the caller was provided by
        {next_write_operation}. }
        {- [`Closed] indicates that the output destination will no longer
        accept bytes from the write processor. }} *)

  val yield_writer : t -> (unit -> unit) -> unit
  (** [yield_writer t continue] registers with the connection to call
      [continue] when writing should resume. {!yield_writer} should be called
      after {!next_write_operation} returns a [`Yield] value. *)

  val report_exn : t -> exn -> unit
  (** [report_exn t exn] reports that an error [exn] has been caught and
      that it has been attributed to [t]. Calling this function will swithc [t]
      into an error state. Depending on the state [t] is transitioning from, it
      may call its error handler before terminating the connection. *)

  val is_closed : t -> bool

  (**/**)
  val shutdown : t -> unit
  (**/**)
end *)

(**/**)


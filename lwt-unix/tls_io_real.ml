open Lwt.Infix

let _ = Nocrypto_entropy_lwt.initialize ()

module Io : Http2af_lwt.IO with
    type socket = Lwt_unix.file_descr * Tls_lwt.Unix.t
    and type addr = Unix.sockaddr = struct
  type socket = Lwt_unix.file_descr * Tls_lwt.Unix.t
  type addr = Unix.sockaddr

  let read (_, tls) bigstring ~off ~len =
    Lwt.catch
      (fun () ->
        Tls_lwt.Unix.read_bytes tls bigstring off len)
      (function
      | Unix.Unix_error (Unix.EBADF, _, _) as exn ->
        Lwt.fail exn
      | exn ->
        Lwt.async (fun () ->
          Tls_lwt.Unix.close tls);
        Lwt.fail exn)
    >>= fun bytes_read ->
    if bytes_read = 0 then
      Lwt.return `Eof
    else
      Lwt.return (`Ok bytes_read)

  let writev (_, tls) = fun iovecs ->
    Lwt.catch
      (fun () ->
        let cstruct_iovecs = List.map (fun { Faraday.len; buffer; off } ->
          Cstruct.of_bigarray ~off ~len buffer)
          iovecs
        in
        Tls_lwt.Unix.writev tls cstruct_iovecs
        >|= fun () ->
          `Ok (Cstruct.lenv cstruct_iovecs))
      (function
      | Unix.Unix_error (Unix.EBADF, "check_descriptor", _) ->
        Lwt.return `Closed
      | exn -> Lwt.fail exn)

  let shutdown_send (_, tls) =
    ignore (Tls_lwt.Unix.close_tls tls)

  let shutdown_receive (_, tls) =
    ignore (Tls_lwt.Unix.close_tls tls)

  let close (_, tls) =
    Tls_lwt.Unix.close tls

  let report_exn connection (socket, _) = fun exn ->
    (* This needs to handle two cases. The case where the socket is
     * still open and we can gracefully respond with an error, and the
     * case where the client has already left. The second case is more
     * common when communicating over HTTPS, given that the remote peer
     * can close the connection without requiring an acknowledgement:
     *
     * From RFC5246§7.2.1:
     *   Unless some other fatal alert has been transmitted, each party
     *   is required to send a close_notify alert before closing the
     *   write side of the connection.  The other party MUST respond
     *   with a close_notify alert of its own and close down the
     *   connection immediately, discarding any pending writes. It is
     *   not required for the initiator of the close to wait for the
     *   responding close_notify alert before closing the read side of
     *   the connection. *)
    Printf.eprintf "EXN SOMETHING: %B %s %s\n%!"
      (Lwt_unix.state socket == Lwt_unix.Closed)
      (Printexc.to_string exn)
      (Printexc.get_backtrace ());

    begin match Lwt_unix.state socket with
    | Aborted _
    | Closed ->
      Http2af.Server_connection.shutdown connection
    | Opened ->
      Http2af.Server_connection.report_exn connection exn
    end;
    Lwt.return_unit
end

type client = Tls_lwt.Unix.t
type server = Tls.Config.server

let make_client ?client socket =
  match client with
  | Some client -> Lwt.return client
  | None ->
    X509_lwt.authenticator `No_authentication_I'M_STUPID >>= fun authenticator ->
    let config = Tls.Config.client ~authenticator () in
    Tls_lwt.Unix.client_of_fd config socket

let make_server ?server ?certfile ?keyfile socket =
  let config = match server, certfile, keyfile with
  | Some server, _, _ -> Lwt.return server
  | None, Some cert, Some priv_key ->
    X509_lwt.private_of_pems ~cert ~priv_key >|= fun certificate ->
    Tls.Config.server
      ~alpn_protocols:["h2"]
      ~certificates:(`Single certificate)
      (* ~version:Tls.Core.(TLS_1_2, TLS_1_2) *)
      ~ciphers:(List.filter Tls.Ciphersuite.ciphersuite_tls12_only Tls.Config.Ciphers.supported)
      ()
  | _ ->
    Lwt.fail (Invalid_argument "Certfile and Keyfile required when server isn't provided")
  in
  config >>= fun config -> Tls_lwt.Unix.server_of_fd config socket



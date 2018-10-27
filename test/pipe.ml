open Test_helpers

let filename = "pipe"

let with_pipe f =
  let pipe =
    Luv.Pipe.init ()
    |> check_success_result "init"
  in

  f pipe;

  Luv.Handle.close pipe;
  run ();

  Alcotest.(check bool) "file deleted" false (Sys.file_exists filename)

let with_server_and_client ?for_handle_passing () ~server_logic ~client_logic =
  let server =
    Luv.Pipe.init ?for_handle_passing ()
    |> check_success_result "server init"
  in
  Luv.Pipe.bind server filename |> check_success "bind";
  Luv.Stream.listen server begin fun result ->
    check_success "listen" result;
    let client =
      Luv.Pipe.init ?for_handle_passing ()
      |> check_success_result "remote client init"
    in
    Luv.Stream.accept ~server ~client |> check_success "accept";
    server_logic server client
  end;

  let client =
    Luv.Pipe.init ?for_handle_passing ()
    |> check_success_result "client init"
  in
  Luv.Pipe.connect client filename begin fun result ->
    check_success "connect" result;
    client_logic client
  end;

  run ();

  Alcotest.(check bool) "file deleted" false (Sys.file_exists filename)

(* TODO This should be written in C and implemented by luv. *)
let unix_fd_to_file : Unix.file_descr -> Luv.File.t =
  Obj.magic

let tests = [
  "pipe", [
    "init, close", `Quick, begin fun () ->
      with_pipe ignore
    end;

    "bind", `Quick, begin fun () ->
      with_pipe begin fun pipe ->
        Luv.Pipe.bind pipe filename
        |> check_success "bind";

        Alcotest.(check bool) "created" true (Sys.file_exists filename)
      end
    end;

    "listen, accept", `Quick, begin fun () ->
      let accepted = ref false in
      let connected = ref false in

      with_server_and_client ()
        ~server_logic:
          begin fun server client ->
            Luv.Pipe.getsockname client
            |> check_success_result "getsockname result"
            |> Alcotest.(check string) "getsockname address" filename;
            accepted := true;
            Luv.Handle.close client;
            Luv.Handle.close server
          end
        ~client_logic:
          begin fun client ->
            Luv.Pipe.getpeername client
            |> check_success_result "getpeername result"
            |> Alcotest.(check string) "getpeername address" filename;
            connected := true;
            Luv.Handle.close client
          end;

      Alcotest.(check bool) "accepted" true !accepted;
      Alcotest.(check bool) "connected" true !connected
    end;

    "read, write", `Quick, begin fun () ->
      let write_finished = ref false in
      let read_finished = ref false in

      with_server_and_client ()
        ~server_logic:
          begin fun server client ->
            Luv.Stream.read_start client begin fun result ->
              let (buffer, length) = check_success_result "read_start" result in

              Alcotest.(check int) "length" 3 length;
              Alcotest.(check char) "byte 0" 'f' (Bigarray.Array1.get buffer 0);
              Alcotest.(check char) "byte 1" 'o' (Bigarray.Array1.get buffer 1);
              Alcotest.(check char) "byte 2" 'o' (Bigarray.Array1.get buffer 2);

              Luv.Handle.close client;
              Luv.Handle.close server;

              read_finished := true
            end
          end
        ~client_logic:
          begin fun client ->
            let buffer1 = Bigarray.(Array1.create Char C_layout 2) in
            let buffer2 = Bigarray.(Array1.create Char C_layout 1) in

            Bigarray.Array1.set buffer1 0 'f';
            Bigarray.Array1.set buffer1 1 'o';
            Bigarray.Array1.set buffer2 0 'o';

            Luv.Stream.write client [buffer1; buffer2] begin fun result ->
              check_success "write" result;
              Luv.Handle.close client;
              write_finished := true
            end
          end;

      Alcotest.(check bool) "write finished" true !write_finished;
      Alcotest.(check bool) "read finished" true !read_finished
    end;

    "open_, receive_handle, write2", `Quick, begin fun () ->
      let wrap ~for_handle_passing fd =
        let pipe =
          Luv.Pipe.init ~for_handle_passing () |> check_success_result "init" in
        Luv.Pipe.open_ pipe (unix_fd_to_file fd) |> check_success "open_";
        pipe
      in

      let ipc_1, ipc_2 = Unix.(socketpair PF_UNIX SOCK_STREAM) 0 in
      let ipc_1 = wrap ~for_handle_passing:true ipc_1 in
      let ipc_2 = wrap ~for_handle_passing:true ipc_2 in

      let passed_1, passed_2 = Unix.(socketpair PF_UNIX SOCK_STREAM) 0 in
      let passed_1 = wrap ~for_handle_passing:false passed_1 in
      let passed_2 = wrap ~for_handle_passing:false passed_2 in

      Luv.Stream.read_start ipc_1 begin fun result ->
        Luv.Stream.read_stop ipc_1 |> check_success "read_stop";

        check_success_result "read_start" result
        |> snd
        |> Alcotest.(check int) "read byte count" 1;

        begin match Luv.Pipe.receive_handle ipc_1 with
        | `Pipe accept ->
          let received =
            Luv.Pipe.init () |> check_success_result "init received" in
          accept received |> check_success "handle accept";
          let buffer = Luv.Bigstring.create 1 in
          Bigarray.Array1.set buffer 0 'x';
          Luv.Stream.try_write received [buffer]
          |> check_success_result "try_write"
          |> Alcotest.(check int) "write byte count" 1;
          Luv.Handle.close received
        | `TCP _ ->
          ignore (Alcotest.fail "expected a pipe, got a TCP handle")
        | `None ->
          ignore (Alcotest.fail "expected a pipe, got nothing")
        end
      end;

      let buffer = Luv.Bigstring.create 1 in
      Luv.Stream.write2 ipc_2 [buffer] ~send_handle:passed_1 begin fun result ->
        check_success "write2" result
      end;

      let did_read = ref false in

      Luv.Stream.read_start passed_2 begin fun result ->
        Luv.Stream.read_stop passed_2 |> check_success "read_stop";
        let buffer, byte_count = check_success_result "read_start" result in
        Alcotest.(check int) "read byte count" 1 byte_count;
        Alcotest.(check char) "data" 'x' (Bigarray.Array1.get buffer 0);
        did_read := true
      end;

      run ();

      Luv.Handle.close ipc_1;
      Luv.Handle.close ipc_2;
      Luv.Handle.close passed_1;
      Luv.Handle.close passed_2;

      run ();

      Alcotest.(check bool) "did read" true !did_read
    end;

    (* TODO Does sending a 0-length buffer result in a segfault? *)

    "chmod, unbound", `Quick, begin fun () ->
      with_pipe begin fun pipe ->
        Luv.Pipe.(chmod pipe Mode.readable)
        |> check_error_code "chmod" Luv.Error.ebadf
      end
    end;

    "chmod", `Quick, begin fun () ->
      with_pipe begin fun pipe ->
        Luv.Pipe.bind pipe filename
        |> check_success "bind";

        Luv.Pipe.(chmod pipe Mode.readable)
        |> check_success "chmod"
      end
    end;
  ]
]

(* This file is part of Luv, released under the MIT license. See LICENSE.md for
   details, or visit https://github.com/aantron/luv/blob/master/LICENSE.md. *)



open Test_helpers

let filename = "fs_event"

let with_fs_event f =
  if Sys.file_exists filename then
    Sys.remove filename;

  let event = Luv.FS_event.init () |> check_success_result "init" in

  f event;

  Luv.Handle.close event ignore;
  run ()

let tests = [
  "fs_event", [
    "init, close", `Quick, begin fun () ->
      with_fs_event ignore
    end;

    "start, stop", `Quick, begin fun () ->
      with_fs_event begin fun event ->
        let occurred = ref false in
        let timed_out = ref false in

        Luv.FS_event.start
          event Filename.current_dir_name (fun _ -> occurred := true);

        let timer = Luv.Timer.init () |> check_success_result "timer" in
        Luv.Timer.start timer 10 begin fun () ->
          Luv.FS_event.stop event |> check_success "stop";
          Luv.Handle.close timer ignore;
          timed_out := true
        end
        |> check_success "timer_start";

        run ();

        Alcotest.(check bool) "timed out" true !timed_out;
        Alcotest.(check bool) "occurred" false !occurred
      end
    end;

    "create", `Quick, begin fun () ->
      with_fs_event begin fun event ->
        let occurred = ref false in

        Luv.FS_event.start event Filename.current_dir_name begin fun result ->
          Luv.FS_event.stop event |> check_success "stop";
          let filename', events = check_success_result "start" result in
          Alcotest.(check string) "filename" filename filename';
          Alcotest.(check bool) "rename"
            true (Luv.FS_event.Event.(test events rename));
          Alcotest.(check bool) "change"
            false (Luv.FS_event.Event.(test events change));
          occurred := true
        end;

        open_out filename |> close_out;

        run ();

        Alcotest.(check bool) "occurred" true !occurred
      end
    end;
  ]
]

module Flag = C.Types.Process.Flag
module Redirection = C.Types.Process.Redirection

type t = [ `Process ] Handle.t

type redirection = int * Redirection.t

module Pipe_mode =
struct
  type t = int
  let readable = Redirection.readable_pipe
  let writable = Redirection.writable_pipe
  let (lor) = (lor)
end

let no_redirection =
  let redirection = Ctypes.make Redirection.t in
  Ctypes.setf redirection Redirection.flags Redirection.ignore;
  redirection

let to_new_pipe
    ?(mode_in_child = Pipe_mode.(readable lor writable))
    ?(overlapped = false)
    ~fd ~to_parent_pipe () =

  let redirection = Ctypes.make Redirection.t in
  let flags = Redirection.create_pipe lor mode_in_child in
  let flags =
    if overlapped then flags lor Redirection.overlapped_pipe
    else flags
  in
  Ctypes.setf redirection Redirection.flags flags;
  Ctypes.setf redirection Redirection.stream Handle.(coerce to_parent_pipe);
  (fd, redirection)

let inherit_fd ~fd ~from_parent_fd =
  let redirection = Ctypes.make Redirection.t in
  Ctypes.setf redirection Redirection.flags Redirection.inherit_fd;
  Ctypes.setf redirection Redirection.fd from_parent_fd;
  (fd, redirection)

let inherit_stream ~fd ~from_parent_stream =
  let redirection = Ctypes.make Redirection.t in
  Ctypes.setf redirection Redirection.flags Redirection.inherit_stream;
  Ctypes.setf redirection Redirection.stream Handle.(coerce from_parent_stream);
  (fd, redirection)

let stdin = 0
let stdout = 1
let stderr = 2

let find_redirection child_fd redirections =
  try
    redirections
    |> List.find (fun (fd, _) -> fd = child_fd)
    |> snd
  with Not_found ->
    no_redirection

let max_redirected_fd redirections =
  redirections
  |> List.map fst
  |> List.fold_left Pervasives.max 3
  (* libuv requires at least 3 redirections (for STDIN, STDOUT, STDERR). *)

let build_redirection_array redirections =
  let length = max_redirected_fd redirections in
  let array = Ctypes.CArray.make Redirection.t length in
  for index = 0 to length - 1 do
    Ctypes.CArray.set array index (find_redirection index redirections)
  done;
  (Ctypes.CArray.start array, length)

let trampoline =
  C.Functions.Process.get_trampoline ()

let null_callback =
  C.Functions.Process.get_null_callback ()

(* TODO Is this legitimate in terms of memory management? *)
let c_string_array strings =
  strings @ [""]
  |> Ctypes.(CArray.of_list string)
  |> Ctypes.CArray.start

let spawn
    ?loop
    ?on_exit
    ?environment
    ?working_directory
    ?(redirect = [])
    ?uid
    ?gid
    ?windows_verbatim_arguments
    ?detached
    ?windows_hide
    path arguments =

  let loop = Loop.or_default loop in
  let process = Handle.allocate C.Types.Process.t in

  let callback =
    match on_exit with
    | Some callback ->
      Handle.set_reference process (fun process exit_status term_signal ->
        try callback process ~exit_status ~term_signal
        with exn -> Error.unhandled_exception exn);
      trampoline
    | None ->
      null_callback
  in

  let env, env_count, set_env =
    match environment with
    | Some env ->
      let env = List.map (fun (key, value) -> key ^ "=" ^ value) env in
      (env, List.length env, true)
    | None ->
      ([], 0, false)
  in

  let cwd, do_cwd =
    match working_directory with
    | Some dir -> (dir, true)
    | None -> ("", false)
  in

  let flags = 0 in

  let uid_or_gid_flag id flag flags =
    match id with
    | Some id -> (id, flags lor flag)
    | None -> (0, flags)
  in
  let uid, flags = uid_or_gid_flag uid Flag.setuid flags in
  let gid, flags = uid_or_gid_flag gid Flag.setgid flags in

  let maybe_flag argument flag flags =
    match argument with
    | Some true -> flags lor flag
    | _ -> flags
  in
  let flags =
    flags
    |> maybe_flag windows_verbatim_arguments Flag.windows_verbatim_arguments
    |> maybe_flag detached Flag.detached
    |> maybe_flag windows_hide Flag.windows_hide
  in

  let redirections, redirection_count = build_redirection_array redirect in

  let result =
    C.Functions.Process.spawn
      loop
      process
      callback
      (Ctypes.ocaml_string_start path)
      (c_string_array arguments)
      (List.length arguments)
      (c_string_array env)
      env_count
      set_env
      (Ctypes.ocaml_string_start cwd)
      do_cwd
      flags
      redirection_count
      redirections
      uid
      gid
  in

  if result < Error.success then begin
    Handle.close process
  end;

  Error.to_result process result

let disable_stdio_inheritance =
  C.Functions.Process.disable_stdio_inheritance

let kill =
  C.Functions.Process.process_kill

let kill_pid ~pid signal =
  C.Functions.Process.kill pid signal

let pid =
  C.Functions.Process.get_pid

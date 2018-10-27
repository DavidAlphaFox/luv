(* This is given the internal name Request_ to avoid shadowing request.mli in
   for code in this file. *)
module Request_ =
struct
  type t = [ `File ] Request.t

  let make () =
    Request.allocate C.Types.File.Request.t

  let or_make maybe_request =
    match maybe_request with
    | Some request -> request
    | None -> make ()

  let cleanup request =
    C.Functions.File.req_cleanup (Request.c request)

  let result request =
    Request.c request
    |> C.Functions.File.get_result
    |> PosixTypes.Ssize.to_int
    |> Error.coerce
    |> Error.clamp

  let file request =
    let file_or_error =
      Request.c request
      |> C.Functions.File.get_result
      |> PosixTypes.Ssize.to_int
    in
    Error.to_result file_or_error (Error.coerce file_or_error)

  let byte_count request =
    let count_or_error = C.Functions.File.get_result (Request.c request) in
    if PosixTypes.Ssize.(compare count_or_error zero) >= 0 then
      count_or_error
      |> PosixTypes.Ssize.to_int64
      |> Unsigned.Size_t.of_int64
      |> fun n -> Result.Ok n
    else
      count_or_error
      |> PosixTypes.Ssize.to_int
      |> Error.coerce
      |> fun n -> Result.Error n

  let path request =
    Request.c request
    |> C.Functions.File.get_path
end

module Bit_flag_operations =
struct
  type t = int
  let (lor) = (lor)
  let list flags = List.fold_left (lor) 0 flags
end

module Open_flag =
struct
  include C.Types.File.Open_flag
  include Bit_flag_operations
  let custom i = i
end

module Mode =
struct
  include C.Types.File.Mode
  include Bit_flag_operations

  let none = 0
  let octal i = i

  let file_default = octal 0o644
  let directory_default = octal 0o755
end

module Dirent =
struct
  module Kind =
  struct
    include C.Types.File.Dirent.Kind
    type t = int
  end

  type t = {
    kind : Kind.t;
    name : string;
  }
end

module Directory_scan =
struct
  type t = {
    request : Request_.t;
    dirent : C.Types.File.Dirent.t;
  }

  let stop scan =
    Request_.cleanup scan.request

  let next scan =
    let result =
      C.Functions.File.scandir_next
        (Request.c scan.request) (Ctypes.addr scan.dirent)
    in
    if result <> Error.success then begin
      stop scan;
      None
    end
    else begin
      let kind = Ctypes.getf scan.dirent C.Types.File.Dirent.type_ in
      let name = Ctypes.getf scan.dirent C.Types.File.Dirent.name in
      Some Dirent.{kind; name}
    end

  let start request =
    let dirent = Ctypes.make C.Types.File.Dirent.t in
    {request; dirent}
end

module Stat =
struct
  type timespec = {
    sec : Signed.Long.t;
    nsec : Signed.Long.t;
  }

  type t = {
    dev : Unsigned.UInt64.t;
    mode : Mode.t;
    nlink : Unsigned.UInt64.t;
    uid : Unsigned.UInt64.t;
    gid : Unsigned.UInt64.t;
    rdev : Unsigned.UInt64.t;
    ino : Unsigned.UInt64.t;
    size : Unsigned.UInt64.t;
    blksize : Unsigned.UInt64.t;
    blocks : Unsigned.UInt64.t;
    flags : Unsigned.UInt64.t;
    gen : Unsigned.UInt64.t;
    atim : timespec;
    mtim : timespec;
    ctim : timespec;
    birthtim : timespec;
  }

  let load_timespec c_timespec =
    {
      sec = Ctypes.getf c_timespec C.Types.File.Timespec.tv_sec;
      nsec = Ctypes.getf c_timespec C.Types.File.Timespec.tv_nsec;
    }

  let load request =
    let c_stat =
      Ctypes.(!@) (C.Functions.File.get_statbuf (Request.c request)) in
    let field f = Ctypes.getf c_stat f in
    let module C_stat = C.Types.File.Stat in
    {
      dev = field C_stat.st_dev;
      mode = field C_stat.st_mode |> Unsigned.UInt64.to_int;
      nlink = field C_stat.st_nlink;
      uid = field C_stat.st_uid;
      gid = field C_stat.st_gid;
      rdev = field C_stat.st_rdev;
      ino = field C_stat.st_ino;
      size = field C_stat.st_size;
      blksize = field C_stat.st_blksize;
      blocks = field C_stat.st_blocks;
      flags = field C_stat.st_flags;
      gen = field C_stat.st_gen;
      atim = load_timespec (field C_stat.st_atim);
      mtim = load_timespec (field C_stat.st_mtim);
      ctim = load_timespec (field C_stat.st_ctim);
      birthtim = load_timespec (field C_stat.st_birthtim);
    }
end

module Copy_flag =
struct
  include C.Types.File.Copy_flag
  include Bit_flag_operations
  let none = 0
end

module Access_flag =
struct
  include C.Types.File.Access_flag
  include Bit_flag_operations
end

module Symlink_flag =
struct
  include C.Types.File.Symlink_flag
  include Bit_flag_operations
  let none = 0
end

module Returns =
struct
  let id e = e
  let construct_error e = Result.Error e

  type 'a t = {
    from_request : Request_.t -> 'a;
    immediate_error : Error.t -> 'a;
    clean_up_request_on_success : bool;
  }

  let returns_error = {
    from_request = Request_.result;
    immediate_error = id;
    clean_up_request_on_success = true;
  }

  let returns_file = {
    from_request = Request_.file;
    immediate_error = construct_error;
    clean_up_request_on_success = true;
  }

  let returns_byte_count = {
    from_request = Request_.byte_count;
    immediate_error = construct_error;
    clean_up_request_on_success = true;
  }

  let returns_path = {
    from_request = (fun request ->
      Error.to_result_lazy
        (fun () -> Request_.path request) (Request_.result request));
    immediate_error = construct_error;
    clean_up_request_on_success = true;
  }

  let returns_directory_scan = {
    from_request = (fun request ->
      Error.to_result_lazy
        (fun () -> Directory_scan.start request) (Request_.result request));
    immediate_error = construct_error;
    clean_up_request_on_success = false;
  }

  let returns_stat = {
    from_request = (fun request ->
      Error.to_result_lazy
        (fun () -> Stat.load request) (Request_.result request));
    immediate_error = construct_error;
    clean_up_request_on_success = true;
  }

  let returns_string = {
    from_request = (fun request ->
      Error.to_result_lazy
        (fun () -> C.Functions.File.get_ptr (Request.c request))
        (Request_.result request));
    immediate_error = construct_error;
    clean_up_request_on_success = true;
  }
end

module Args =
struct
  let string s = fun f -> f (Ctypes.ocaml_string_start s)
  let uint i = fun f -> f (Unsigned.UInt.of_int i)

  let (!) v = fun f -> f v
  let (@@) a b = fun f -> b (a f)
end

type t = C.Types.File.t

module type ASYNC_OR_SYNC =
sig
  type 'value cps_or_normal_return
  type 'fn maybe_with_loop_and_request_arguments

  (* DOC This type is not meant to be understood. *)
  val async_or_sync :
    (Loop.t -> Request_.t -> 'c_signature) ->
    'result Returns.t ->
    ((('c_signature -> C.Functions.File.trampoline -> Error.t) ->
      (unit -> unit) ->
        'result cps_or_normal_return) ->
       'ocaml_signature) ->
      'ocaml_signature maybe_with_loop_and_request_arguments
end

module Make_functions (Async_or_sync : ASYNC_OR_SYNC) =
struct
  open Returns
  open Args

  let async_or_sync = Async_or_sync.async_or_sync

  let no_cleanup = ignore

  let open_ =
    async_or_sync
      C.Functions.File.open_
      returns_file
      (fun run ?(mode = Mode.file_default) path flags ->
        run (string path @@ !flags @@ !mode) no_cleanup)

  let close =
    async_or_sync
      C.Functions.File.close
      returns_error
      (fun run file -> run !file no_cleanup)

  let read_or_write c_function =
    async_or_sync
      c_function
      returns_byte_count
      (fun run ?(offset = -1L) file buffers ->
        let count = List.length buffers in
        let iovecs = Misc.Buf.bigstrings_to_iovecs buffers count in
        run
          (!file @@ !iovecs @@ uint count @@ !offset)
          (fun () ->
            C.Functions.Buf.free (Ctypes.to_voidp iovecs);
            ignore (Sys.opaque_identity buffers)))

    let read = read_or_write C.Functions.File.read
    let write = read_or_write C.Functions.File.write

  let unlink =
    async_or_sync
      C.Functions.File.unlink
      returns_error
      (fun run path -> run (string path) no_cleanup)

  let mkdir =
    async_or_sync
      C.Functions.File.mkdir
      returns_error
      (fun run ?(mode = Mode.directory_default) path ->
        run (string path @@ !mode) no_cleanup)

  let mkdtemp =
    async_or_sync
      C.Functions.File.mkdtemp
      returns_path
      (fun run path -> run (string path) no_cleanup)

  let rmdir =
    async_or_sync
      C.Functions.File.rmdir
      returns_error
      (fun run path -> run (string path) no_cleanup)

  let scandir =
    async_or_sync
      C.Functions.File.scandir
      returns_directory_scan
      (fun run path -> run (string path @@ !0) no_cleanup)

  let generic_stat c_function pass =
    async_or_sync
      c_function
      returns_stat
      (fun run argument -> run (pass argument) no_cleanup)

  let stat = generic_stat C.Functions.File.stat string
  let lstat = generic_stat C.Functions.File.lstat string
  let fstat = generic_stat C.Functions.File.fstat (!)

  let rename =
    async_or_sync
      C.Functions.File.rename
      returns_error
      (fun run ~from ~to_ -> run (string from @@ string to_) no_cleanup)

  let generic_fsync c_function =
    async_or_sync
      c_function
      returns_error
      (fun run file -> run !file no_cleanup)

  let fsync = generic_fsync C.Functions.File.fsync
  let fdatasync = generic_fsync C.Functions.File.fdatasync

  let ftruncate =
    async_or_sync
      C.Functions.File.ftruncate
      returns_error
      (fun run file length -> run (!file @@ !length) no_cleanup)

  let copyfile =
    async_or_sync
      C.Functions.File.copyfile
      returns_error
      (fun run ~from ~to_ flags ->
        run (string from @@ string to_ @@ !flags) no_cleanup)

  let sendfile =
    async_or_sync
      C.Functions.File.sendfile
      returns_byte_count
      (fun run ~to_ ~from ~offset length ->
        run (!to_ @@ !from @@ !offset @@ !length) no_cleanup)

  let access =
    async_or_sync
      C.Functions.File.access
      returns_error
      (fun run path mode -> run (string path @@ !mode) no_cleanup)

  let generic_chmod c_function pass =
    async_or_sync
      c_function
      returns_error
      (fun run argument mode -> run (pass argument @@ !mode) no_cleanup)

  let chmod = generic_chmod C.Functions.File.chmod string
  let fchmod = generic_chmod C.Functions.File.fchmod (!)

  let generic_utime c_function pass =
    async_or_sync
      c_function
      returns_error
      (fun run argument ~atime ~mtime ->
        run (pass argument @@ !atime @@ !mtime) no_cleanup)

  let utime = generic_utime C.Functions.File.utime string
  let futime = generic_utime C.Functions.File.futime (!)

  let link =
    async_or_sync
      C.Functions.File.link
      returns_error
      (fun run ~target ~link -> run (string target @@ string link) no_cleanup)

  let symlink =
    async_or_sync
      C.Functions.File.symlink
      returns_error
      (fun run ~target ~link flags ->
        run (string target @@ string link @@ !flags) no_cleanup)

  let generic_readpath c_function =
    async_or_sync
      c_function
      returns_string
      (fun run path -> run (string path) no_cleanup)

  let readlink = generic_readpath C.Functions.File.readlink
  let realpath = generic_readpath C.Functions.File.realpath

  let generic_chown c_function pass =
    async_or_sync
      c_function
      returns_error
      (fun run argument uid gid ->
        run (pass argument @@ !uid @@ !gid) no_cleanup)

  let chown = generic_chown C.Functions.File.chown string
  let fchown = generic_chown C.Functions.File.fchown (!)
end

module Async =
struct
  let trampoline =
    C.Functions.File.get_trampoline ()

  let async c_function returns get_args =
    fun ?loop ?request ->
      get_args begin fun args cleanup callback ->
        let loop = Loop.or_default loop in
        let request = Request_.or_make request in

        Request.set_callback_1 request begin fun request ->
          let result = Returns.(returns.from_request request) in
          if Returns.(returns.clean_up_request_on_success)
            || Request_.result request < Error.success then begin
            Request_.cleanup request
          end;
          cleanup ();
          callback result
        end;

        let immediate_result =
          ((c_function loop (Request.c request)) |> args) trampoline in

        if immediate_result < Error.success then begin
          Request.clear_callback request;
          Request_.cleanup request;
          cleanup ();
          callback (Returns.(returns.immediate_error) immediate_result)
        end
      end

  include Make_functions
    (struct
      type 'value cps_or_normal_return = ('value -> unit) -> unit
      type 'fn maybe_with_loop_and_request_arguments =
        ?loop:Loop.t -> ?request:Request_.t -> 'fn
      let async_or_sync = async
    end)
end

module Sync =
struct
  let null_callback =
    C.Functions.File.get_null_callback ()

  let sync c_function returns get_args =
    get_args begin fun args cleanup ->
      let request = Request_.make () in
      let immediate_result =
        ((c_function (Loop.default ()) (Request.c request)) |> args)
          null_callback
      in

      cleanup ();
      let result =
        if immediate_result < Error.success then
          Returns.(returns.immediate_error) immediate_result
        else
          Returns.(returns.from_request) request
      in
      if Returns.(returns.clean_up_request_on_success)
        || immediate_result < Error.success then begin
        Request_.cleanup request;
      end;
      result
    end

  include Make_functions
    (struct
      type 'value cps_or_normal_return = 'value
      type 'fn maybe_with_loop_and_request_arguments = 'fn
      let async_or_sync = sync
    end)
end

module Request = Request_

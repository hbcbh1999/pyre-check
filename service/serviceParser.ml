(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Ast
open Pyre
open PyreParser

module Scheduler = ServiceScheduler
module AstSharedMemory = ServiceAstSharedMemory


let parse_path_to_source file =
  File.path file |> Path.relative
  >>= fun path ->
  File.lines file
  >>= fun lines ->
  let metadata = Source.Metadata.parse path lines in
  try
    let statements = Parser.parse ~path lines in
    Some (
      Source.create
        ~docstring:(Statement.extract_docstring statements)
        ~metadata
        ~path
        ~qualifier:(Source.qualifier ~path)
        statements)
  with
  | Parser.Error error ->
      Log.log ~section:`Parser "%s" error;
      None
  | Failure error ->
      Log.error "%s" error;
      None


let parse_parallel ~scheduler ~job ~files =
  Scheduler.map_reduce
    scheduler
    ~init:[]
    ~map:(fun _ files -> job ~files)
    ~reduce:(fun new_sources parsed_sources -> parsed_sources @ new_sources)
    files


let parse_job ~configuration:{ Configuration.verbose; sections; _ } ~files =
  Log.initialize ~verbose ~sections;
  let parse handles file =
    (file
     |> parse_path_to_source
     >>= fun source ->
     Path.relative (File.path file)
     >>| fun relative ->
     let preprocess_qualifier ({ Source.path; qualifier; _ } as source) =
       let qualifier =
         if String.is_suffix ~suffix:".pyi" path then
           (* Drop version from qualifier. *)
           let is_digit qualifier =
             try
               qualifier
               |> Int.of_string
               |> ignore;
               true
             with _ ->
               false
           in
           begin
             match source.Source.qualifier with
             | minor :: major :: tail
               when is_digit (Expression.Access.show [minor]) &&
                    is_digit (Expression.Access.show [major]) ->
                 tail
             | major :: tail when is_digit (String.prefix (Expression.Access.show [major]) 1) ->
                 tail
             | qualifier ->
                 qualifier
           end
         else
           qualifier
       in
       { source with Source.qualifier }
     in
     let handle = File.Handle.create relative in
     source
     |> preprocess_qualifier
     |> Analysis.Preprocessing.preprocess
     |> AstSharedMemory.add_source handle;
     handle :: handles)
    |> Option.value ~default:handles
  in
  List.fold ~init:[] ~f:parse files


let parse_sources_list ~configuration ~scheduler ~files =
  let handles =
    if Scheduler.is_parallel scheduler then
      parse_parallel ~scheduler ~job:(parse_job ~configuration) ~files
    else
      parse_job ~configuration ~files
  in
  handles


let log_parse_errors_count ~not_parsed ~description =
  if not_parsed > 0 then
    begin
      Log.warning "Could not parse %d %s%s due to syntax errors!"
        not_parsed
        description
        (if not_parsed > 1 then "s" else "");
      if not (Log.is_enabled `Parser) then
        Log.warning "You can use --show-parse-errors for more details."
    end


let parse_stubs
    scheduler
    ~configuration:({ Configuration.source_root; stub_roots; _ } as configuration) =
  let timer = Timer.start () in

  let paths =
    let stubs =
      let stubs root =
        Log.info "Finding type stubs in `%a`..." Path.pp root;
        let is_stub path =
          let is_python_2_stub path =
            String.is_substring ~substring:"/2/" path ||
            String.is_substring ~substring:"/2.7/" path
          in
          String.is_suffix path ~suffix:".pyi" && not (is_python_2_stub path)
        in
        File.list ~filter:is_stub ~root
      in
      List.concat_map ~f:stubs (source_root :: stub_roots)
    in
    let modules =
      let modules root =
        Log.info "Finding external sources in `%a`..." Path.pp root;
        File.list ~filter:(String.is_suffix ~suffix:".py") ~root
      in
      List.concat_map ~f:modules stub_roots
    in
    stubs @ modules
  in

  Log.info "Parsing %d stubs and external sources..." (List.length paths);
  let handles =
    parse_sources_list ~configuration ~scheduler ~files:(List.map ~f:File.create paths)
  in
  Statistics.performance ~name:"stubs parsed" ~timer ~configuration ();
  let not_parsed = (List.length paths) - (List.length handles) in
  log_parse_errors_count ~not_parsed ~description:"external file";
  handles


let find_sources ?(filter = fun _ -> true) { Configuration.source_root; _ } =
  let filter path = String.is_suffix ~suffix:".py" path && filter path in
  File.list ~filter ~root:source_root


let parse_sources
    ?(filter = fun _ -> true)
    scheduler
    ~configuration:({ Configuration.source_root; _ } as configuration) =
  let timer = Timer.start () in
  let paths = find_sources configuration ~filter in
  Log.info "Parsing %d sources in `%a`..." (List.length paths) Path.pp source_root;
  let handles =
    parse_sources_list ~configuration ~scheduler ~files:(List.map ~f:File.create paths)
  in
  let not_parsed = (List.length paths) - (List.length handles) in
  log_parse_errors_count ~not_parsed ~description:"file";

  Statistics.performance ~name:"sources parsed" ~timer ~configuration ();
  handles

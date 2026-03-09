let read_file path =
  if Sys.file_exists path then
    Some (In_channel.with_open_text path In_channel.input_all)
  else None

let rec ensure_dir path =
  if path = "." || path = "/" || path = "" then ()
  else if Sys.file_exists path then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)

let ensure_parent_dir path = ensure_dir (Filename.dirname path)

let contains text snippet =
  let text_len = String.length text in
  let snippet_len = String.length snippet in
  if snippet_len = 0 then true
  else
    let rec loop i =
      if i + snippet_len > text_len then false
      else if String.sub text i snippet_len = snippet then true
      else loop (i + 1)
    in
    loop 0

let parse_key_value_output text =
  let add_pair acc line =
    match String.split_on_char '=' line with
    | key :: value_parts when key <> "" ->
        let value = String.concat "=" value_parts |> String.trim in
        if value = "" then acc else (String.trim key, value) :: acc
    | _ -> acc
  in
  text |> String.split_on_char '\n' |> List.fold_left add_pair [] |> List.rev

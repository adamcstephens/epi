type t = string

let to_string target = target

let of_string target =
  match String.split_on_char '#' target with
  | [ flake_ref; config_name ] when flake_ref = "" || config_name = "" ->
    Error
      (`Msg
        "both flake reference and config name are required in --target \
         <flake-ref>#<config-name>")
  | [ _flake_ref; _config_name ] -> Ok target
  | _ -> Error (`Msg "--target must use <flake-ref>#<config-name>")
;;

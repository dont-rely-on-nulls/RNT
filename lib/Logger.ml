type level = Debug | Info | Warn | Error | Fatal

type colors = Foreground | Blue | Yellow | Red | Purple

let reset = "\027[0m"
let bold = "\027[1m"

let color_for = function
  | Foreground -> "\027[39m"
  | Blue -> "\027[34m"
  | Yellow -> "\027[33m"
  | Red -> "\027[31m"
  | Purple -> "\027[35m"

let colored color text = Printf.sprintf "%s%s%s%s" (color_for color) bold text reset

let channel_for = function
  | Warn | Error | Fatal -> stderr
  | _ -> stdout

let prefix_for = function
  | Debug -> colored Foreground "[DEBUG]"
  | Info -> colored Blue "[INFO]"
  | Warn -> colored Yellow "[WARN]"
  | Error -> colored Red "[ERROR]"
  | Fatal -> colored Purple "[FATAL]"

let log level message =
  Printf.fprintf (channel_for level) "%s %s\n" (prefix_for level) message

(**
  {1 Schemas}

  Schemas are a lightweight formalism to represent patterns in free text.
  A schema can be compiled down to an ocaml parser recognizing it.

  {2 General idea}

  Suppose we want to parse sentences similar to ["x is the sum of y and z"] but where
  ["x"], ["y"] and ["z"] can be any sequence of words denoting a mathematical expression and ["sum"]
  my be any binary operation (e.g. ["product"], ["division"], ["subtraction"], ...).
  Providing we already defined a parser [expr] recognizing expressions and a parser [op] recognizing
  binary operation names, a good schema to parse such declarations would be
  ["$expr is the $operation of $expr and $expr"].

  {2 Using Ppxs to compile schemas}

  Schemas are intended to be compiled down to efficient OCaml parsers. Such parsers are of the form [char list -> (t, char list) option]
  where [t] is the type of the structure we want to parse. Thus, compiled schemas are compliant with the {! Combinators] api and can be easily}
  combined and integrated in a more standard parser.
  
  Compilation of schemas is performed at ocaml's compile time via the use of syntax extensions (so called Ppx).
  To compile a schema an action should be provided. Actions are simply functions that are called each time a schema is detected.
  Subpatterns discovered during the execution of a schema parser are given as labeled arguments to the action function.

  {[
let declaration =
  let op = operation_parser in
  let expr = expression_parser in
  let action ~expr1 ~op1 ~expr2 () = (op1, expr1, expr2) in
  [@schema "$expr is the $op of $expr and $expr", action]
  ]}
*)


open Combinators
open Ppxlib

type token =
  | Word of string
  | Ref of string

type schema = token list list

let p_alpha =
  check (function 'a'..'z' | 'A'..'Z' -> true | _ -> false)

let p_ident =
  implode <$> many1 p_alpha

let p_word = (fun x -> Word x) <$> p_ident

let p_ref = (fun x -> Ref x) <$> check ((=) '$') *> p_ident

let p_spaces = many (check ((=) ' '))

let schema =
  many1 (p_spaces *> (p_word <|> p_ref))

let incr_ref h r =
  if Hashtbl.mem h r then
    Hashtbl.replace h r ((Hashtbl.find h r) + 1)
  else
    Hashtbl.add h r 1

let count_ref s =
  let h = Hashtbl.create 10 in
  let n = ref 0 in
  List.iter (function
    | Ref r -> incr n; incr_ref h r
    | Word _ -> ()
  ) s; h, !n

let compile_schema ?fname:(fname = "") ?lno:(lno = 1) ~loc txt action =
  let open (Ast_builder.Make (struct let loc = loc end)) in
  let (toks, _) = try Option.get (schema (explode txt)) with _ ->
    Ppxlib.Location.raise_errorf ~loc "File '%s', line %d:\nunable to parse schema '%s'" fname lno txt
  in
  let (refs, nrefs) = count_ref toks in
  let h = Hashtbl.create 10 in
  let get r = incr_ref h r; Hashtbl.find h r in
  let mk_tmp r = ppat_var {txt = (r ^ string_of_int (nrefs - (get r) + 1)); loc} in
  let args =
    Hashtbl.to_seq refs
    |> List.of_seq
    |> List.concat_map (fun (r, n) -> List.init n (fun i -> r ^ string_of_int (i + 1)))
  in
  let cunit = Nolabel, pexp_construct {txt=Lident "()"; loc} None in
  let ret = pexp_apply action ((List.map (fun x -> Labelled x, evar x) args) @ [cunit]) in
  List.fold_left (fun acc e ->
    match e with
    | Word w -> [%expr let* _ = p_spaces *> token [%e estring w] in [%e acc]]
    | Ref r  -> [%expr let* [%p mk_tmp r] = p_spaces *> [%e evar r] in [%e acc]]
  ) [%expr return [%e ret]] (List.rev toks)

let load_schemas ~loc fname action =
  let read_all input =
    let dict = ref [] in
    try while true do
      dict := (input_line input |> String.trim)::!dict
    done; assert false
    with End_of_file -> List.rev !dict
  in
  let input = try open_in fname with _ ->
    Ppxlib.Location.raise_errorf ~loc "unable to open file '%s'" fname
  in
  let schemas = List.mapi 
    (fun i s -> compile_schema ~lno:(i + 1) ~fname ~loc s action)
    (read_all input)
  in
  [%expr choice [%e Ppxlib.Ast_builder.Default.elist ~loc schemas]]

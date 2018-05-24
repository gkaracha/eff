let help_text =
  "Toplevel commands:\n"
  ^ "#type <expr>;;     print the type of <expr> without evaluating it\n"
  ^ "#reset;;           forget all definitions (including pervasives)\n"
  ^ "#help;;            print this help\n" ^ "#quit;;            exit eff\n"
  ^ "#use \"<file>\";;  load commands from file\n"


module TypeSystem = SimpleInfer
module EffectSystem = ExplicitInfer
module Runtime = Eval

type state =
  { desugarer_state: Desugarer.state
  ; type_system_state: TypeSystem.state
  ; effect_system_state: EffectSystem.state
  ; type_checker_state: TypeChecker.state
  ; runtime_state: Runtime.state }

let initial_state =
  { desugarer_state= Desugarer.initial_state
  ; type_system_state= TypeSystem.initial_state
  ; effect_system_state= EffectSystem.initial_state
  ; type_checker= TypeChecker.initial_state
  ; runtime_state= Runtime.initial_state }


let _ = Random.self_init ()

(* [exec_cmd ppf st cmd] executes toplevel command [cmd] in a state [st].
   It prints the result to [ppf] and returns the new state. *)
let rec exec_cmd ppf st {CoreUtils.it= cmd; CoreUtils.at= loc} =
  match cmd with
  | Commands.Term t ->
      let c = Desugarer.desugar_computation st.desugarer_state t in
      let type_system_state', ty =
        TypeSystem.infer_top_comp st.type_system_state c
      in
      let c', effect_system_state' =
        ExplicitInfer.type_toplevel ~loc:c.CoreSyntax.location
          st.effect_system_state c
      in
      let ty, drt = TypeChecker.type_of_computation st.type_checker_state ct in
      let v = Runtime.run st.runtime_state c in
      Format.fprintf ppf "@[- : %t / %t ! %t = %t@]@."
        (Type.print_beautiful ty) (Types.print_target_ty ty)
        (Types.print_target_dirt drt)
        (Value.print_value v) ;
      { st with
        type_system_state= type_system_state'
      ; effect_system_state= effect_system_state' }
  | Commands.TypeOf t ->
      let c = Desugarer.desugar_computation st.desugarer_state t in
      let type_system_state', ty =
        TypeSystem.infer_top_comp st.type_system_state c
      in
      let c', effect_system_state' =
        ExplicitInfer.type_toplevel ~loc:c.CoreSyntax.location
          st.effect_system_state c
      in
      let ty, drt = TypeChecker.type_of_computation st.type_checker_state ct in
      Format.fprintf ppf "@[- : %t / %t ! %t@]@." (Type.print_beautiful ty)
        (Types.print_target_ty ty)
        (Types.print_target_dirt drt) ;
      { st with
        type_system_state= type_system_state'
      ; effect_system_state= effect_system_state' }
  | Commands.Reset ->
      Format.fprintf ppf "Environment reset." ;
      Tctx.reset () ;
      initial_state
  | Commands.Help ->
      Format.fprintf ppf "%s" help_text ;
      st
  | Commands.DefEffect effect_def ->
      let eff, (ty1, ty2) =
        Desugarer.desugar_def_effect st.desugarer_state effect_def
      in
      let type_system_state' =
        SimpleCtx.add_effect st.type_system_state eff (ty1, ty2)
      in
      let effect_system_state' =
        ExplicitInfer.add_effect eff (ty1, ty2) st.effect_system_state
      in
      { st with
        type_system_state= type_system_state'
      ; effect_system_state= effect_system_state' }
  | Commands.Quit -> exit 0
  | Commands.Use filename -> execute_file ppf filename st
  | Commands.TopLet defs ->
      let desugarer_state', defs' =
        Desugarer.desugar_top_let st.desugarer_state defs
      in
      let vars, type_system_state' =
        TypeSystem.infer_top_let ~loc st.type_system_state defs'
      in
      let runtime_state' =
        List.fold_right
          (fun (p, c) env ->
            let v = Runtime.run env c in
            Runtime.extend p v env )
          defs' st.runtime_state
      in
      List.iter
        (fun (x, tysch) ->
          match Runtime.lookup x runtime_state' with
          | None -> assert false
          | Some v ->
              Format.fprintf ppf "@[val %t : %t = %t@]@."
                (UntypedSyntax.Variable.print x)
                (Type.print_beautiful tysch)
                (Value.print_value v) )
        vars ;
      { desugarer_state= desugarer_state'
      ; type_system_state= type_system_state'
      ; runtime_state= runtime_state' }
  | Commands.TopLetRec defs ->
      let desugarer_state', defs' =
        Desugarer.desugar_top_let_rec st.desugarer_state defs
      in
      let vars, type_system_state' =
        TypeSystem.infer_top_let_rec ~loc st.type_system_state defs'
      in
      let defs'' = Assoc.of_list defs' in
      let runtime_state' = Runtime.extend_let_rec st.runtime_state defs'' in
      List.iter
        (fun (x, tysch) ->
          Format.fprintf ppf "@[val %t : %t = <fun>@]@."
            (UntypedSyntax.Variable.print x)
            (Type.print_beautiful tysch) )
        vars ;
      { desugarer_state= desugarer_state'
      ; type_system_state= type_system_state'
      ; runtime_state= runtime_state' }
  | Commands.External ext_def -> (
      let desugarer_state', (x, ty, f) =
        Desugarer.desugar_external st.desugarer_state ext_def
      in
      match Assoc.lookup f External.values with
      | Some v ->
          { desugarer_state= desugarer_state'
          ; type_system_state=
              SimpleCtx.extend st.type_system_state x (Type.free_params ty, ty)
          ; runtime_state= Runtime.update x v st.runtime_state }
      | None -> Error.runtime "unknown external symbol %s." f )
  | Commands.Tydef tydefs ->
      let desugarer_state', tydefs' =
        Desugarer.desugar_tydefs st.desugarer_state tydefs
      in
      Tctx.extend_tydefs ~loc tydefs' ;
      {st with desugarer_state= desugarer_state'}


and exec_cmds ppf state cmds = CoreUtils.fold (exec_cmd ppf) state cmds

(* Parser wrapper *)
and parse lexbuf =
  try Parser.commands Lexer.token lexbuf with
  | Parser.Error ->
      Error.syntax ~loc:(Location.of_lexeme lexbuf) "parser error"
  | Failure failmsg when failmsg = "lexing: empty token" ->
      Error.syntax ~loc:(Location.of_lexeme lexbuf) "unrecognised symbol."


and execute_file ppf filename env =
  Lexer.read_file parse filename |> exec_cmds ppf env


and execute_source ppf str env =
  Lexer.read_string parse str |> exec_cmds ppf env


let compile_file ppf filename st =
  let out_channel = open_out (filename ^ ".ml") in
  let out_ppf = Format.formatter_of_out_channel out_channel in
  (* look for header.ml next to the executable  *)
  let header_file_basename =
    match !Config.backend with
    | Config.MulticoreOCaml -> "backendHeaderMulticoreOCaml.ml"
    | Config.PlainOCaml -> "backendHeaderPlainOCaml.ml"
  in
  let header_file =
    Filename.concat (Filename.dirname Sys.argv.(0)) header_file_basename
  in
  let header_channel = open_in header_file in
  let n = in_channel_length header_channel in
  let header = really_input_string header_channel n in
  close_in header_channel ;
  Format.fprintf out_ppf "%s\n;;\n@." header ;
  let compile_cmd st cmd =
    let loc = cmd.CoreSyntax.location in
    match cmd.CoreSyntax.term with
    | CoreSyntax.Computation c ->
        Print.debug "Compiling: %t" (CoreSyntax.print_computation c) ;
        let ct, explicit_typing =
          ExplicitInfer.type_toplevel ~loc st.explicit_typing c
        in
        Print.debug
          "-- After Type Inference ----------------------------------------" ;
        Print.debug "%t" (Typed.print_computation ct) ;
        let ct =
          if !Config.disable_optimization then ct
          else Optimize.optimize_main_comp st.type_checker ct
        in
        Print.debug
          "-- After Optimization ------------------------------------------" ;
        Print.debug "%t" (Typed.print_computation ct) ;
        let ct_ty, ct_dirt =
          TypeChecker.type_of_computation st.type_checker ct
        in
        Print.debug "Type from Type Checker : %t ! %t"
          (Types.print_target_ty ct_ty)
          (Types.print_target_dirt ct_dirt) ;
        let erasure_ct = Erasure.typed_to_erasure_comp [] ct in
        ( match !Config.backend with
        | MulticoreOCaml ->
            CodegenMulticoreOCaml.print_computation erasure_ct out_ppf
        | PlainOCaml -> CodegenPlainOCaml.print_computation erasure_ct out_ppf
        ) ;
        Format.fprintf out_ppf "\n;;\n " ;
        print_endline "ended found something!" ;
        {st with explicit_typing}
    | CoreSyntax.DefEffect (eff, (ty1, ty2)) ->
        let explicit_typing =
          ExplicitInfer.add_effect eff (ty1, ty2) st.explicit_typing
        in
        Print.print out_ppf
          "type (_, _) effect += Effect_%s : (int, int) effect" eff ;
        Format.fprintf out_ppf "\n;;\n " ;
        {st with explicit_typing}
    | CoreSyntax.External (x, ty, f) -> (
      match OldUtils.lookup f External.values with
      | Some v ->
          let new_ty = Types.source_to_target ty in
          Print.print out_ppf "let %t = ( %s )"
            (CodegenPlainOCaml.print_variable x)
            f ;
          Format.fprintf out_ppf "\n;;\n " ;
          { st with
            typing= SimpleCtx.extend st.typing x (Type.free_params ty, ty)
          ; explicit_typing=
              { st.explicit_typing with
                ExplicitInfer.context=
                  TypingEnv.update st.explicit_typing.context x new_ty }
          ; type_checker= TypeChecker.extend_var_types st.type_checker x new_ty
          ; runtime= Eval.update x v st.runtime }
      | None -> Error.runtime "unknown external symbol %s." f )
    | _ -> st
  in
  let cmds = Lexer.read_file parse filename in
  let st, cmds =
    List.fold_left
      (fun (st, cmds) cmd ->
        let desugar_st, cmd = Desugar.toplevel st.desugaring cmd in
        ({st with desugaring= desugar_st}, cmd :: cmds) )
      (st, []) cmds
  in
  let st = List.fold_left compile_cmd st (List.rev cmds) in
  Format.fprintf out_ppf "@? " ;
  flush out_channel ;
  close_out out_channel ;
  st
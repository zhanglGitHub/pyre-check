(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open Pyre
open Ast
open Analysis
open Expression

type incompatible_model_error_reason =
  | UnexpectedPositionalOnlyParameter of string
  | UnexpectedNamedParameter of string
  | UnexpectedStarredParameter
  | UnexpectedDoubleStarredParameter

type verification_error =
  | GlobalVerificationError of {
      name: string;
      message: string;
    }
  | InvalidDefaultValue of {
      callable_name: string;
      name: string;
      expression: Expression.t;
    }
  | IncompatibleModelError of {
      name: string;
      callable_type: Type.Callable.t;
      reasons: incompatible_model_error_reason list;
    }
  | ImportedFunctionModel of {
      name: Reference.t;
      actual_name: Reference.t;
    }
  (* TODO(T81363867): Remove this variant. *)
  | UnclassifiedError of string

let display_verification_error ~path ~location error =
  let model_origin =
    match path with
    | None -> ""
    | Some path ->
        Format.sprintf " defined in `%s:%d`" (Path.absolute path) Location.(location.start.line)
  in
  match error with
  | GlobalVerificationError { name; message } ->
      Format.asprintf "Invalid model for `%s`%s: %s" name model_origin message
  | InvalidDefaultValue { callable_name; name; expression } ->
      Format.sprintf
        "Invalid model for `%s`%s: Default values of parameters must be `...`. Did you mean to \
         write `%s: %s`?"
        callable_name
        model_origin
        name
        (Expression.show expression)
  | IncompatibleModelError { name; callable_type; reasons } ->
      let reasons =
        List.map reasons ~f:(function
            | UnexpectedPositionalOnlyParameter name ->
                Format.sprintf "unexpected positional only parameter: `%s`" name
            | UnexpectedNamedParameter name ->
                Format.sprintf "unexpected named parameter: `%s`" name
            | UnexpectedStarredParameter -> "unexpected star parameter"
            | UnexpectedDoubleStarredParameter -> "unexpected star star parameter")
      in
      Format.asprintf
        "Invalid model for `%s`%s: Model signature parameters do not match implementation `%s`. \
         Reason%s: %s."
        name
        model_origin
        (Type.show_for_hover (Type.Callable callable_type))
        (if List.length reasons > 1 then "s" else "")
        (String.concat reasons ~sep:"; ")
  | ImportedFunctionModel { name; actual_name } ->
      Format.asprintf
        "Invalid model for `%a`%s: The modelled function is an imported function `%a`, please \
         model it directly."
        Reference.pp
        name
        model_origin
        Reference.pp
        actual_name
  | UnclassifiedError error -> error


type parameter_requirements = {
  anonymous_parameters_count: int;
  parameter_set: String.Set.t;
  has_star_parameter: bool;
  has_star_star_parameter: bool;
}

let create_parameters_requirements ~type_parameters =
  let get_parameters_requirements requirements type_parameter =
    let open Type.Callable.RecordParameter in
    match type_parameter with
    | PositionalOnly _ ->
        {
          requirements with
          anonymous_parameters_count = requirements.anonymous_parameters_count + 1;
        }
    | Named { name; _ }
    | KeywordOnly { name; _ } ->
        let name = Identifier.sanitized name in
        { requirements with parameter_set = String.Set.add requirements.parameter_set name }
    | Variable _ -> { requirements with has_star_parameter = true }
    | Keywords _ -> { requirements with has_star_star_parameter = true }
  in
  let init =
    {
      anonymous_parameters_count = 0;
      parameter_set = String.Set.empty;
      has_star_parameter = false;
      has_star_star_parameter = false;
    }
  in
  List.fold_left type_parameters ~f:get_parameters_requirements ~init


let demangle_class_attribute name =
  if String.is_substring ~substring:"__class__" name then
    String.split name ~on:'.'
    |> List.rev
    |> function
    | attribute :: "__class__" :: rest -> List.rev (attribute :: rest) |> String.concat ~sep:"."
    | _ -> name
  else
    name


let model_compatible ~callable_name ~callable_type ~type_parameters ~normalized_model_parameters =
  let open Result in
  let parameter_requirements = create_parameters_requirements ~type_parameters in
  (* Once a requirement has been satisfied, it is removed from requirement object. At the end, we
     check whether there remains unsatisfied requirements. *)
  let validate_model_parameter errors_and_requirements (model_parameter, _, original) =
    (* Ensure that the parameter's default value is either not present or `...` to catch common
       errors when declaring models. *)
    let errors_and_requirements =
      match Node.value original with
      | { Parameter.value = Some expression; name; _ } ->
          if not (Expression.equal_expression (Node.value expression) Expression.Ellipsis) then
            Error (InvalidDefaultValue { callable_name; name; expression })
          else
            errors_and_requirements
      | _ -> errors_and_requirements
    in
    let open AccessPath.Root in
    errors_and_requirements
    >>| fun (errors, requirements) ->
    match model_parameter with
    | LocalResult
    | Variable _ ->
        failwith
          ( "LocalResult|Variable won't be generated by AccessPath.Root.normalize_parameters, "
          ^ "and they cannot be compared with type_parameters." )
    | PositionalParameter { name; positional_only = true; _ } ->
        let { anonymous_parameters_count; _ } = requirements in
        if anonymous_parameters_count >= 1 then
          errors, { requirements with anonymous_parameters_count = anonymous_parameters_count - 1 }
        else
          UnexpectedPositionalOnlyParameter name :: errors, requirements
    | PositionalParameter { name; _ }
    | NamedParameter { name } ->
        let name = Identifier.sanitized name in
        if String.is_prefix name ~prefix:"__" then (* It is an positional only parameter. *)
          let { anonymous_parameters_count; has_star_parameter; _ } = requirements in
          if anonymous_parameters_count >= 1 then
            ( errors,
              { requirements with anonymous_parameters_count = anonymous_parameters_count - 1 } )
          else if has_star_parameter then
            (* If all positional only parameter quota is used, it might be covered by a `*args` *)
            errors, requirements
          else
            UnexpectedPositionalOnlyParameter name :: errors, requirements
        else
          let { parameter_set; has_star_parameter; has_star_star_parameter; _ } = requirements in
          (* Consume an required or optional named parameter. *)
          if String.Set.mem parameter_set name then
            let parameter_set = String.Set.remove parameter_set name in
            errors, { requirements with parameter_set }
          else if has_star_parameter || has_star_star_parameter then
            (* If the name is not found in the set, it might be covered by ``**kwargs` *)
            errors, requirements
          else
            UnexpectedNamedParameter name :: errors, requirements
    | StarParameter _ ->
        if requirements.has_star_parameter then
          errors, requirements
        else
          UnexpectedStarredParameter :: errors, requirements
    | StarStarParameter _ ->
        if requirements.has_star_star_parameter then
          errors, requirements
        else
          UnexpectedDoubleStarredParameter :: errors, requirements
  in
  let errors_and_requirements =
    List.fold_left
      normalized_model_parameters
      ~f:validate_model_parameter
      ~init:(Result.Ok ([], parameter_requirements))
  in
  errors_and_requirements
  >>= fun (errors, _) ->
  if List.is_empty errors then
    Result.Ok ()
  else
    Result.Error (IncompatibleModelError { name = callable_name; callable_type; reasons = errors })


let verify_signature ~normalized_model_parameters ~name callable_annotation =
  match callable_annotation with
  | Some
      ( {
          Type.Callable.implementation =
            { Type.Callable.parameters = Type.Callable.Defined implementation_parameters; _ };
          kind;
          _;
        } as callable ) -> (
      match kind with
      | Type.Callable.Named actual_name when not (Reference.equal name actual_name) ->
          Error (ImportedFunctionModel { name; actual_name })
      | _ ->
          model_compatible
            ~callable_name:(Reference.show name)
            ~callable_type:callable
            ~type_parameters:implementation_parameters
            ~normalized_model_parameters )
  | _ -> Result.Ok ()


let verify_global ~resolution ~name =
  let name = demangle_class_attribute (Reference.show name) |> Reference.create in
  let global_resolution = Resolution.global_resolution resolution in
  let global = GlobalResolution.global global_resolution name in
  if Option.is_some global then
    Result.Ok ()
  else
    let class_summary, attribute_name =
      ( Reference.as_list name
        |> List.drop_last
        >>| Reference.create_from_list
        >>| Reference.show
        >>| (fun class_name -> Type.Primitive class_name)
        >>= GlobalResolution.class_definition global_resolution
        >>| Node.value,
        Reference.last name )
    in
    match class_summary with
    | Some { ClassSummary.attribute_components; name = class_name; _ } ->
        let attributes, constructor_attributes =
          ( Statement.Class.attributes ~include_generated_attributes:false attribute_components,
            Statement.Class.constructor_attributes attribute_components )
        in
        if
          Identifier.SerializableMap.mem attribute_name attributes
          || Identifier.SerializableMap.mem attribute_name constructor_attributes
        then
          Result.Ok ()
        else
          let error =
            Format.sprintf
              "Class `%s` has no attribute `%s`."
              (Reference.show class_name)
              attribute_name
          in
          Result.Error (GlobalVerificationError { name = Reference.show name; message = error })
    | _ ->
        let error =
          Format.sprintf
            "`%s` does not correspond to a class's attribute or a global."
            (Reference.show name)
        in
        Result.Error (GlobalVerificationError { name = Reference.show name; message = error })

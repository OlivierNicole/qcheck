(*
QCheck: Random testing for OCaml
copyright (c) 2013-2017, Guillaume Bury, Simon Cruanes, Vincent Hugot, Jan Midtgaard
all rights reserved.
*)

(** {1 Quickcheck inspired property-based testing} *)

let poly_compare=compare
open Printf

module RS = Random.State

let rec foldn ~f ~init:acc i =
  if i = 0 then acc else foldn ~f ~init:(f acc i) (i-1)

let _opt_map_2 ~f a b = match a, b with
  | Some x, Some y -> Some (f x y)
  | _ -> None

let _opt_map_3 ~f a b c = match a, b, c with
  | Some x, Some y, Some z -> Some (f x y z)
  | _ -> None

let _opt_map_4 ~f a b c d = match a, b, c, d with
  | Some x, Some y, Some z, Some w -> Some (f x y z w)
  | _ -> None

let _opt_sum a b = match a, b with
  | Some _, _ -> a
  | None, _ -> b

let sum_int = List.fold_left (+) 0

exception Failed_precondition
(* raised if precondition is false *)

exception No_example_found of string
(* raised if an example failed to be found *)

let assume b = if not b then raise Failed_precondition

let assume_fail () = raise Failed_precondition

let (==>) b1 b2 = if b1 then b2 else raise Failed_precondition

module Seq = struct

  include Seq

  (* The following functions are copied from https://github.com/ocaml/ocaml/blob/trunk/stdlib/seq.ml to support older OCaml versions. *)

  let rec unfold f u () =
    match f u with
    | None -> Nil
    | Some (x, u') -> Cons (x, unfold f u')

  let rec append seq1 seq2 () =
    match seq1() with
    | Nil -> seq2()
    | Cons (x, next) -> Cons (x, append next seq2)

  let cons x next () = Cons (x, next)

  (* End of copy of old functions. *)

  let is_empty (seq : _ t) : bool = match seq () with
    | Nil -> true
    | _ -> false

  (** Take at most [n] values. *)
  let rec take (n : int) (seq : _ t) : _ t = fun () -> match (n, seq ()) with
    | (0, _) | (_, Nil) -> Nil
    | (n, Cons (a, rest)) -> Cons (a, take (n - 1) rest)


  let hd (l : 'a t) : 'a option =
    match l () with
    | Nil -> None
    | Cons (hd, _) -> Some hd
end

module Shrink = struct

  let number_towards ~(equal : 'a -> 'a -> bool) ~(div : 'a -> 'a -> 'a) ~(add : 'a -> 'a -> 'a) ~(sub : 'a -> 'a -> 'a) ~(of_int : int -> 'a) ~(destination : 'a) (x : 'a) : 'a Seq.t =
    Seq.unfold (fun current_shrink ->
        if equal current_shrink x
        then None
        else
            (*
              Halve the operands before subtracting them so they don't overflow.
              Consider [number_towards min_int max_int]
            *)
          let half_diff =  sub (div x (of_int 2)) (div current_shrink (of_int 2)) in
          if half_diff = of_int 0
          (* [current_shrink] is the last valid shrink candidate, put [x] as next step to make sure we stop *)
          then Some (current_shrink, x)
          else Some (current_shrink, add current_shrink half_diff)
      ) destination

  let int_towards destination x =
    Int.(number_towards ~equal ~div ~add ~sub ~of_int:Fun.id) ~destination x

  let int32_towards destination x =
    Int32.(number_towards ~equal ~div ~add ~sub ~of_int) ~destination x

  let int64_towards destination x =
    Int64.(number_towards ~equal ~div ~add ~sub ~of_int) ~destination x

  (** Arbitrarily limit to 15 elements as dividing a [float] by 2 doesn't converge quickly
      towards the destination. *)
  let float_towards destination x =
    Float.(number_towards ~equal ~div ~add ~sub ~of_int) ~destination x |> Seq.take 15

  let int_aggressive_towards (destination : int) (n : int) : int Seq.t =
    Seq.unfold (fun current ->
        if current = n then None
        else if current < n then let next = succ current in Some (next, next)
        else let next = pred current in Some (next, next)
      ) destination

  let int_aggressive n = int_aggressive_towards 0 n

end

module Tree = struct
  type 'a t = Tree of 'a * ('a t) Seq.t

  let root (Tree (root, _) : 'a t) : 'a = root

  let children (Tree (_, children) : 'a t) : ('a t) Seq.t = children

  let rec pp ?(depth : int option) (inner_pp : Format.formatter -> 'a -> unit) (ppf : Format.formatter) (t : 'a t) : unit =
    let Tree (x, xs) = t in
    let wrapper_box ppf inner =
      Format.fprintf ppf "@[<hv2>Tree(@,%a@]@,)" inner ()
    in
    let inner ppf () =
      Format.fprintf ppf "@[<hv2>Node(@,%a@]@,),@ @[<hv>Shrinks(" inner_pp x;
      if Option.fold depth ~none:false ~some:(fun depth -> depth <= 0) then (
        Format.fprintf ppf "<max depth reached>@])")
      else if Seq.is_empty xs then Format.fprintf ppf "@])"
      else (
        Format.fprintf ppf "@,%a@]@,)"
          (Format.pp_print_list
             ~pp_sep:(fun ppf () -> Format.fprintf ppf ",@ ")
             (pp ?depth:(Option.map pred depth) inner_pp))
          (List.of_seq xs);
      )
    in
    wrapper_box ppf inner

  let rec map (f : 'a -> 'b) (a : 'a t) : 'b t =
    let Tree (x, xs) = a in
    let y = f x in
    let ys = Seq.map (fun smaller_x -> map f smaller_x) xs in
    Tree (y, ys)

  (** Note that parameter order is reversed. *)
  let (>|=) a f = map f a

  let rec ap (f : ('a -> 'b) t) (a : 'a t) : 'b t =
    let Tree (x0, xs) = a in
    let Tree (f0, fs) = f in
    let y = f0 x0 in
    let ys = Seq.append (Seq.map (fun f' -> ap f' a) fs) (Seq.map (fun x' -> ap f x') xs) in
    Tree (y, ys)

  let (<*>) = ap

  let liftA2 (f : 'a -> 'b -> 'c) (a : 'a t) (b : 'b t) : 'c t =
    (a >|= f) <*> b

  let rec bind (a : 'a t) (f : 'a -> 'b t) : 'b t =
    let Tree (x, xs) = a in
    let Tree (y, ys_of_x) = f x in
    let ys_of_xs = Seq.map (fun smaller_x -> bind smaller_x f) xs in
    let ys = Seq.append ys_of_xs ys_of_x in
    Tree (y, ys)

  let (>>=) = bind

  let pure x = Tree (x, Seq.empty)

  let rec make_primitive (shrink : 'a -> 'a Seq.t) (x : 'a) : 'a t =
    let shrink_trees = shrink x |> Seq.map (make_primitive shrink) in
    Tree (x, shrink_trees)

  let rec opt (a : 'a t) : 'a option t =
    let Tree (x, xs) = a in
    let shrinks = Seq.cons (pure None) (Seq.map opt xs) in
    Tree (Some x, shrinks)

  let rec add_shrink_invariant (p : 'a -> bool) (a : 'a t) : 'a t =
    let Tree (x, xs) = a in
    let xs' = Seq.filter_map (fun (Tree (x', _) as t) -> if p x' then Some (add_shrink_invariant p t) else None) xs in
    Tree (x, xs')
end

module Gen = struct

  (* Maybe the type should be changed to [RS.t -> (unit -> 'a) tree] or use laziness? To avoid eagerly evaluating shrinks during generation (see implem of [(>>=)] that requires evaluating to append Sequences). *)
  type 'a t = RS.t -> 'a Tree.t

  type 'a sized = int -> Random.State.t -> 'a Tree.t

  let map f x st = Tree.map f (x st)

  (** Note that parameter order is reversed. *)
  let (>|=) x f = map f x

  let (<$>) = map

  let pure (a : 'a) : 'a t = fun _ -> Tree.pure a

  let ap (f : ('a -> 'b) t) (x : 'a t) : 'b t = fun st -> Tree.ap (f st)  (x st)

  let (<*>) = ap

  let liftA2 (f : 'a -> 'b -> 'c) (a : 'a t) (b : 'b t) : 'c t =
    (a >|= f) <*> b

  let liftA3 (f : 'a -> 'b -> 'c -> 'd) (a : 'a t) (b : 'b t) (c : 'c t) : 'd t =
    (a >|= f) <*> b <*> c

  let map2 = liftA2

  let map3 = liftA3

  let return = pure

  let bind (gen : 'a t) (f : 'a -> ('b t)) : 'b t = fun st -> Tree.bind (gen st) (fun a -> f a st)

  let (>>=) = bind

  let make_primitive ~(gen : Random.State.t -> 'a) ~(shrink : 'a -> 'a Seq.t) : 'a t = fun st ->
    Tree.make_primitive shrink (gen st)

  let parse_origin (loc : string) (pp : Format.formatter -> 'a -> unit) ~(origin : 'a) ~(low : 'a) ~(high : 'a) : 'a =
    if origin < low then invalid_arg Format.(asprintf "%s: origin value %a is lower than low value %a" loc pp origin pp low)
    else if origin > high then invalid_arg Format.(asprintf "%s: origin value %a is greater than high value %a" loc pp origin pp high)
    else origin

  let small_nat : int t = fun st ->
    let p = RS.float st 1. in
    let x = if p < 0.75 then RS.int st 10 else RS.int st 100 in
    Tree.make_primitive (Shrink.int_towards 0) x

  (** Natural number generator *)
  let nat : int t = fun st ->
    let p = RS.float st 1. in
    let x =
      if p < 0.5 then RS.int st 10
      else if p < 0.75 then RS.int st 100
      else if p < 0.95 then RS.int st 1_000
      else RS.int st 10_000
    in Tree.make_primitive (Shrink.int_towards 0) x

  let big_nat : int t = fun st ->
    let p = RS.float st 1. in
    if p < 0.75
    then nat st
    else Tree.make_primitive (Shrink.int_towards 0) (RS.int st 1_000_000)

  let unit : unit t = fun _st -> Tree.pure ()

  let bool : bool t = fun st ->
    let false_gen = Tree.pure false in
    if RS.bool st
    then Tree.Tree (true, Seq.return false_gen)
    else false_gen

  let float : float t = fun st ->
    let x = exp (RS.float st 15. *. (if RS.float st 1. < 0.5 then 1. else -1.))
            *. (if RS.float st 1. < 0.5 then 1. else -1.)
    in Tree.make_primitive (Shrink.float_towards 0.) x

  let pfloat : float t = float >|= abs_float

  let nfloat : float t = pfloat >|= Float.neg

  let float_bound_inclusive ?(origin : float = 0.) (bound : float) : float t = fun st ->
    let (low, high) = Float.min_max_num 0. bound in
    let origin = parse_origin "Gen.float_bound_inclusive" Format.pp_print_float ~origin ~low ~high in
    let x = RS.float st bound in
    Tree.make_primitive (Shrink.float_towards origin) x

  let float_bound_exclusive ?(origin : float = 0.) (bound : float) : float t =
    let (low, high) = Float.min_max_num 0. bound in
    let origin = parse_origin "Gen.float_bound_exclusive" Format.pp_print_float ~origin ~low ~high in
    if bound = 0. then invalid_arg "Gen.float_bound_exclusive";
    let bound =
      if bound > 0.
      then bound -. epsilon_float
      else bound +. epsilon_float
    in
    float_bound_inclusive ~origin bound

  let float_range ?(origin : float option) (low : float) (high : float) : float t =
    if high < low then invalid_arg "Gen.float_range: high < low"
    else if high -. low > max_float then invalid_arg "Gen.float_range: high -. low > max_float";
    let origin = parse_origin "Gen.float_range" Format.pp_print_float ~origin:(Option.value ~default:low origin) ~low ~high in
    (float_bound_inclusive ~origin (high -. low))
    >|= (fun x -> low +. x)

  let (--.) low high = float_range ~origin:low low high

  let neg_int : int t = nat >|= Int.neg

  (** [opt gen] shrinks towards [None] then towards shrinks of [gen]. *)
  let opt (gen : 'a t) : 'a option t = fun st ->
    let p = RS.float st 1. in
    if p < 0.15
    then Tree.pure None
    else Tree.opt (gen st)

  (* Uniform positive random int generator.

     We can't use {!Random.State.int} because the upper bound must be positive and is excluded,
     so {!Int.max_int} would never be reached. We have to manipulate bits directly.

     Note that the leftmost bit is used for negative numbers, so it must be [0].

     {!Random.State.bits} only generates 30 bits, which is exactly enough on
     32-bits architectures (i.e. {!Sys.int_size} = 31, i.e. 30 bits for positive numbers)
     but not on 64-bits ones.

     That's why for 64-bits, 3 30-bits segments are generated and shifted to craft a
     62-bits number (i.e. {!Sys.int_size} = 63). The leftmost segment is masked to keep
     only the last 2 bits.

     The current implementation hard-codes 30/32/62/64 values, but technically we should
     rely on {!Sys.int_size} to find the number of bits.

     Note that we could also further generalize this function to merge it with [random_binary_string].
     Technically this function is a special case of [random_binary_string] where the size is
     {!Sys.int_size}.
  *)
  let pint_raw (st : RS.t) : int =
    if Sys.word_size = 32
    then RS.bits st
    else (* word size = 64 *)
      (* Bottom 30 bits *)
      let right = RS.bits st in
      (* Middle 30 bits *)
      let middle = (RS.bits st lsl 30) in
      (* Technically we could write [3] but this is clearer *)
      let two_bits_mask = 0b11 in
      (* Top 2 bits *)
      let left = ((RS.bits st land two_bits_mask) lsl 60) in
      left lor middle lor right

  let pint ?(origin : int = 0) : int t = fun st ->
    let origin = parse_origin "Gen.pint" Format.pp_print_int ~origin ~low:0 ~high:max_int in
    let x = pint_raw st in
    Tree.make_primitive (Shrink.int_towards origin) x

  let number_towards = Shrink.number_towards

  let int_towards = Shrink.int_towards

  let int64_towards = Shrink.int64_towards

  let int32_towards = Shrink.int32_towards

  let float_towards = Shrink.float_towards

  let int : int t =
    bool >>= fun b ->
    if b
    then pint ~origin:0 >|= (fun n -> - n - 1)
    else pint ~origin:0

  let int_bound (n : int) : int t =
    if n < 0 then invalid_arg "Gen.int_bound";
    fun st ->
      if n <= (1 lsl 30) - 2
      then Tree.make_primitive (Shrink.int_towards 0) (Random.State.int st (n + 1))
      else Tree.map (fun r -> r mod (n + 1)) (pint st)

  (** Shrink towards [origin] if provided, otherwise towards the middle of the range
      (e.g. [int_range (-5) 15] will shrink towards [5])

      To support ranges wider than [Int.max_int], the general idea is to find the center,
      and generate a random half-difference number as well as whether we add or
      subtract that number from the center. *)
  let int_range ?(origin : int option) (a : int) (b : int) : int t =
    if b < a then invalid_arg "Gen.int_range: high < low";
    let origin = Option.fold ~none:a ~some:(fun origin ->
        if origin < a
        then invalid_arg "Gen.int_range: origin < low"
        else if origin > b then invalid_arg "Gen.int_range: origin > high"
        else origin) origin in
    fun st ->
      let Tree.Tree(n, _shrinks) = if a >= 0 || b < 0 then (
          (* range smaller than max_int *)
          assert (b-a >= 0);
          Tree.map (fun n -> a + n) (int_bound (b - a) st)
        ) else (
          (* range potentially bigger than max_int: we split on 0 and
             choose the itv wrt to their size ratio *)
          let f_a = float_of_int a in
          let ratio = (-.f_a) /. (1. +. float_of_int b -. f_a) in
          if Random.State.float st 1. <= ratio
          then Tree.map (fun n -> - n - 1) (int_bound (- (a+1)) st)
          else int_bound b st
        ) in
      Tree.make_primitive (Shrink.int_towards origin) n

  let (--) low high = int_range ~origin:low low high

  let oneof (l : 'a t list) : 'a t =
    int_range 0 (List.length l - 1) >>= List.nth l

  let oneofl (l : 'a list) : 'a t =
    int_range 0 (List.length l - 1) >|= List.nth l

  let oneofa (a : 'a array) : 'a t =
    int_range 0 (Array.length a - 1) >|= Array.get a

  (* NOTE: we keep this alias to not break code that uses [small_int]
     for sizes of strings, arrays, etc. *)
  let small_int = small_nat

  let small_signed_int : int t = fun st ->
    if Random.State.bool st
    then small_nat st
    else (small_nat >|= Int.neg) st

  (** Shrink towards the first element of the list *)
  let frequency (l : (int * 'a t) list) : 'a t =
    if l = [] then failwith "QCheck2.frequency called with an empty list";
    let sums = sum_int (List.map fst l) in
    if sums < 1 then failwith "QCheck2.frequency called with weight sum < 1";
    int_bound (sums - 1)
    >>= fun i ->
    let rec aux acc = function
      | ((x,g)::xs) -> if i < acc+x then g else aux (acc+x) xs
      | _ -> failwith "QCheck2.frequency crashed for an unknown reason"
    in
    aux 0 l

  let frequencyl (l : (int * 'a) list) : 'a t =
    List.map (fun (weight, value) -> (weight, pure value)) l
    |> frequency

  let frequencya a = frequencyl (Array.to_list a)

  let char_range ?(origin : char option) (a : char) (b : char) : char t =
    (int_range ~origin:(Char.code (Option.value ~default:a origin)) (Char.code a) (Char.code b)) >|= Char.chr

  let random_binary_string (length : int) (st : Random.State.t) : string =
    (* 0b011101... *)
    let s = Bytes.create (length + 2) in
    Bytes.set s 0 '0';
    Bytes.set s 1 'b';
    for i = 0 to length - 1 do
      Bytes.set s (i+2) (if RS.bool st then '0' else '1')
    done;
    Bytes.unsafe_to_string s

  let int32 : int32 t = fun st ->
    let x = random_binary_string 32 st |> Int32.of_string in
    Tree.make_primitive (int32_towards 0l) x

  (** TODO Not actually unsigned, fix in https://github.com/c-cube/qcheck/issues/105 *)
  let ui32 : int32 t = int32

  let int64 : int64 t = fun st ->
    let x = random_binary_string 64 st |> Int64.of_string in
    Tree.make_primitive (int64_towards 0L) x

  (** TODO Not actually unsigned, fix in https://github.com/c-cube/qcheck/issues/105 *)
  let ui64 : int64 t = int64

  let list_size (size : int t) (gen : 'a t) : 'a list t =
    size >>= fun size ->
    let rec loop n =
      if n <= 0
      then pure []
      else liftA2 (List.cons) gen (loop (n - 1))
    in
    loop size

  let list (gen : 'a t) : 'a list t = list_size nat gen

  let list_repeat (n : int) (gen : 'a t) : 'a list t = list_size (pure n) gen

  let array_size (size : int t) (gen : 'a t) : 'a array t =
    (list_size size gen) >|= Array.of_list

  let array (gen : 'a t) : 'a array t = list gen >|= Array.of_list

  let array_repeat (n : int) (gen : 'a t) : 'a array t = list_repeat n gen >|= Array.of_list

  let rec flatten_l (l : 'a t list) : 'a list t =
    match l with
    | [] -> pure []
    | gen :: gens -> liftA2 List.cons gen (flatten_l gens)

  let flatten_a (a : 'a t array) : 'a array t =
    Array.to_list a |> flatten_l >|= Array.of_list

  let flatten_opt (o : 'a t option) : 'a option t =
    match o with
    | None -> pure None
    | Some gen -> opt gen

  let flatten_res (res : ('a t, 'e) result) : ('a, 'e) result t =
    match res with
    | Ok gen -> gen >|= Result.ok
    | Error e -> pure (Error e)

  let shuffle_a (a : 'a array) : 'a array t = fun st ->
    let a = Array.copy a in
    for i = Array.length a-1 downto 1 do
      let j = Random.State.int st (i+1) in
      let tmp = a.(i) in
      a.(i) <- a.(j);
      a.(j) <- tmp;
    done;
    Tree.pure a

  let shuffle_l (l : 'a list) : 'a list t = fun st ->
    let a = Array.of_list l in
    let _ = shuffle_a a st in
    Tree.pure (Array.to_list a)

  let shuffle_w_l (l : ((int * 'a) list)) : 'a list t = fun st ->
    let sample (w, v) =
      let Tree.Tree (p, _) = float_bound_inclusive 1. st in
      let fl_w = float_of_int w in
      (p ** (1. /. fl_w), v)
    in
    let samples = List.rev_map sample l in
    samples
    |> List.sort (fun (w1, _) (w2, _) -> poly_compare w1 w2)
    |> List.rev_map snd
    |> Tree.pure

  let pair (g1 : 'a t) (g2 : 'b t) : ('a * 'b) t = liftA2 (fun a b -> (a, b)) g1 g2

  let triple (g1 : 'a t) (g2 : 'b t) (g3 : 'c t) : ('a * 'b * 'c) t = (g1 >|= (fun a b c -> (a, b, c))) <*> g2 <*> g3

  let quad (g1 : 'a t) (g2 : 'b t) (g3 : 'c t) (g4 : 'd t) : ('a * 'b * 'c * 'd) t =
    (g1 >|= (fun a b c d -> (a, b, c, d))) <*> g2 <*> g3 <*> g4

  let char : char t = int_range ~origin:(int_of_char 'a') 0 255 >|= char_of_int

  (** The first characters are the usual lower case alphabetical letters to help shrinking. *)
  let printable_chars =
    (* Left and right inclusive *)
    let range min max = List.init (max - min) (fun i -> char_of_int (i + min)) in
    let a = 97 in
    let z = 122 in
    let lower_alphabet = range a z in
    (* ' ' *)
    let first_printable_char = 32 in
    let before_lower_alphabet = range first_printable_char (a - 1) in
    (* '~' *)
    let last_printable_char = 126 in
    let after_lower_alphabet = range (z + 1) last_printable_char in
    let newline = ['\n'] in
    (* Put alphabet first for shrinking *)
    List.flatten [lower_alphabet; before_lower_alphabet; after_lower_alphabet; newline]

  let printable : char t =
    int_range ~origin:0 0 (List.length printable_chars - 1)
    >|= List.nth printable_chars

  let numeral : char t =
    let zero = 48 in
    let nine = 57 in
    int_range ~origin:zero zero nine >|= char_of_int

  let string_size ?(gen = char) (size : int t) : string t =
    list_size size gen >|= (fun l -> List.to_seq l |> String.of_seq)

  let string ?(gen : char t option) : string t = string_size ?gen nat

  let string_of gen = string_size ~gen nat

  let string_readable = string_size ~gen:char nat

  let small_string ?gen st = string_size ?gen small_nat st

  let small_list gen = list_size small_nat gen

  let small_array gen = array_size small_nat gen

  let join (gen : 'a t t) : 'a t =
    gen >>= Fun.id

  (* corner cases *)

  let graft_corners (gen : 'a t) (corners : 'a list) () : 'a t =
    let cors = ref corners in fun st ->
      match !cors with [] -> gen st
                     | e::l -> cors := l; Tree.pure e

  let int_pos_corners = [0;1;2;max_int]

  let int_corners = int_pos_corners @ [min_int]

  let nng_corners () : int t = graft_corners nat int_pos_corners ()

  (* sized, fix *)

  let sized_size (size : int t) (gen : 'a sized) : 'a t =
    size >>= gen

  let sized (gen : 'a sized) : 'a t = sized_size nat gen

  let fix f =
    let rec f' n st = f f' n st in
    f'

  let generate ?(rand=Random.State.make_self_init()) ~(n : int) (gen : 'a t) : 'a list =
    list_repeat n gen rand |> Tree.root

  let generate1 ?(rand=Random.State.make_self_init()) (gen : 'a t) : 'a =
    gen rand |> Tree.root

  let generate_tree ?(rand=Random.State.make_self_init()) (gen : 'a t) : 'a Tree.t =
    gen rand

  let delay (f : unit -> 'a t) : 'a t = fun st -> f () st

  let add_shrink_invariant (p : 'a -> bool) (gen : 'a t) : 'a t =
    fun st -> gen st |> Tree.add_shrink_invariant p

  include Qcheck_ops.Make(struct
      type nonrec 'a t = 'a t
      let (>|=) = (>|=)
      let monoid_product a b = (a >|= (fun x y -> (x, y))) <*> b
      let (>>=) = (>>=)
    end)
end

module Print = struct
  type 'a t = 'a -> string

  let unit _ = "()"

  let int = string_of_int

  let bool = string_of_bool

  let float = string_of_float

  let string s = s

  let char c = String.make 1 c

  let option f = function
    | None -> "None"
    | Some x -> "Some (" ^ f x ^ ")"

  let pair a b (x,y) = Printf.sprintf "(%s, %s)" (a x) (b y)

  let triple a b c (x,y,z) = Printf.sprintf "(%s, %s, %s)" (a x) (b y) (c z)

  let quad a b c d (x,y,z,w) =
    Printf.sprintf "(%s, %s, %s, %s)" (a x) (b y) (c z) (d w)

  let list pp l =
    let b = Buffer.create 25 in
    Buffer.add_char b '[';
    List.iteri (fun i x ->
        if i > 0 then Buffer.add_string b "; ";
        Buffer.add_string b (pp x))
      l;
    Buffer.add_char b ']';
    Buffer.contents b

  let array pp a =
    let b = Buffer.create 25 in
    Buffer.add_string b "[|";
    Array.iteri (fun i x ->
        if i > 0 then Buffer.add_string b "; ";
        Buffer.add_string b (pp x))
      a;
    Buffer.add_string b "|]";
    Buffer.contents b

  let contramap f p x = p (f x)

  let comap = contramap
end

(** {2 Observe Values} *)

module Observable = struct
  (** An observable is a (random) predicate on ['a] *)
  type -'a t = {
    print: 'a Print.t;
    eq: ('a -> 'a -> bool);
    hash: ('a -> int);
  }

  let hash o x = o.hash x

  let equal o x y = o.eq x y

  let print o x = o.print x

  let make ?(eq=(=)) ?(hash=Hashtbl.hash) print =
    {print; eq; hash; }

  module H = struct
    let combine a b = Hashtbl.seeded_hash a b

    let combine_f f s x = Hashtbl.seeded_hash s (f x)

    let int i = i land max_int

    let bool b = if b then 1 else 2

    let char x = Char.code x

    let string (x:string) = Hashtbl.hash x

    let opt f = function
      | None -> 42
      | Some x -> combine 43 (f x)
    let list f l = List.fold_left (combine_f f) 0x42 l

    let array f l = Array.fold_left (combine_f f) 0x42 l

    let pair f g (x,y) = combine (f x) (g y)
  end

  module Eq = struct
    type 'a t = 'a -> 'a -> bool

    let int : int t = (=)

    let string : string t = (=)

    let bool : bool t = (=)

    let float : float t = (=)

    let unit () () = true

    let char : char t = (=)

    let rec list f l1 l2 = match l1, l2 with
      | [], [] -> true
      | [], _ | _, [] -> false
      | x1::l1', x2::l2' -> f x1 x2 && list f l1' l2'

    let array eq a b =
      let rec aux i =
        if i = Array.length a then true
        else eq a.(i) b.(i) && aux (i+1)
      in
      Array.length a = Array.length b
      &&
      aux 0

    let option f o1 o2 = match o1, o2 with
      | None, None -> true
      | Some _, None
      | None, Some _ -> false
      | Some x, Some y -> f x y

    let pair f g (x1,y1)(x2,y2) = f x1 x2 && g y1 y2
  end

  let unit : unit t = make ~hash:(fun _ -> 1) ~eq:Eq.unit Print.unit

  let bool : bool t = make ~hash:H.bool ~eq:Eq.bool Print.bool

  let int : int t = make ~hash:H.int ~eq:Eq.int Print.int

  let float : float t = make ~eq:Eq.float Print.float

  let string = make ~hash:H.string ~eq:Eq.string Print.string

  let char = make ~hash:H.char ~eq:Eq.char Print.char

  let option p =
    make ~hash:(H.opt p.hash) ~eq:(Eq.option p.eq)
      (Print.option p.print)

  let array p =
    make ~hash:(H.array p.hash) ~eq:(Eq.array p.eq) (Print.array p.print)

  let list p =
    make ~hash:(H.list p.hash) ~eq:(Eq.list p.eq) (Print.list p.print)

  let contramap f p =
    make ~hash:(fun x -> p.hash (f x)) ~eq:(fun x y -> p.eq (f x)(f y))
      (fun x -> p.print (f x))

  let map = contramap

  let pair a b =
    make ~hash:(H.pair a.hash b.hash) ~eq:(Eq.pair a.eq b.eq) (Print.pair a.print b.print)

  let triple a b c =
    contramap (fun (x,y,z) -> x,(y,z)) (pair a (pair b c))

  let quad a b c d =
    contramap (fun (x,y,z,u) -> x,(y,z,u)) (pair a (triple b c d))
end

type 'a stat = string * ('a -> int)
(** A statistic on a distribution of values of type ['a] *)

type 'a arbitrary = {
  gen: 'a Gen.t;
  print: ('a -> string) option; (** print values *)
  collect: ('a -> string) option;  (** map value to tag, and group by tag *)
  stats: 'a stat list; (** statistics to collect and print *)
}

let make ?print ?collect ?(stats=[]) gen = {
  gen;
  print;
  collect;
  stats;
}

let set_print f o = {o with print=Some f}

let set_collect f o = {o with collect=Some f}

let set_stats s o = {o with stats=s}

let add_stat s o = {o with stats=s :: o.stats}

let set_gen g o = {o with gen=g}

let add_shrink_invariant (p : 'a -> bool) (arb : 'a arbitrary) : 'a arbitrary =
  {arb with gen = Gen.add_shrink_invariant p arb.gen}

let get_gen o = o.gen

let get_print o = o.print

let choose l =
  match l with
  | [] -> raise (Invalid_argument "QCheck2.choose called with an empty list")
  | l ->
    let gens = List.map get_gen l in
    make (Gen.oneof gens)

let unit : unit arbitrary =
  make ~print:Print.unit Gen.unit

let bool = make ~print:string_of_bool Gen.bool

let float = make ~print:string_of_float Gen.float

let pos_float = make ~print:string_of_float Gen.pfloat

let neg_float = make ~print:string_of_float Gen.nfloat

let float_bound_inclusive ?origin bound =
  make ~print:string_of_float (Gen.float_bound_inclusive ?origin bound)

let float_bound_exclusive ?origin bound =
  make ~print:string_of_float (Gen.float_bound_exclusive ?origin bound)

let float_range ?origin low high = make ~print:string_of_float (Gen.float_range ?origin low high)

let make_int gen = make ~print:Print.int gen

let int = make_int Gen.int

let pos_int = make_int Gen.pint

let int_bound n = make_int (Gen.int_bound n)

let int_range ?origin a b = make_int (Gen.int_range ?origin a b)

let (--) a b = int_range ~origin:a a b

let small_int = make_int Gen.small_nat

let small_nat = make_int Gen.small_nat

let small_signed_int = make_int Gen.small_signed_int

let small_int_corners () = make_int (Gen.nng_corners ())

let neg_int = make_int Gen.neg_int

let int32 = make ~print:(fun i -> Int32.to_string i ^ "l") Gen.int32

let int64 = make ~print:(fun i -> Int64.to_string i ^ "L") Gen.int64

let char = make ~print:(sprintf "%C") Gen.char

let printable_char = make ~print:(sprintf "%C") Gen.printable

let numeral_char = make ~print:(sprintf "%C") Gen.numeral

let string_gen_of_size (size : int Gen.t) (gen : char Gen.t) : string arbitrary =
  make ~print:(sprintf "%S") (Gen.string_size ~gen size)

let string_gen (gen : char Gen.t) : string arbitrary =
  make ~print:(sprintf "%S") (Gen.string ~gen)

let string : string arbitrary = string_gen Gen.char

let string_of_size size = string_gen_of_size size Gen.char

let small_string = string_gen_of_size Gen.small_nat Gen.char

let printable_string = string_gen Gen.printable

let printable_string_of_size size = string_gen_of_size size Gen.printable

let small_printable_string = string_gen_of_size Gen.small_nat Gen.printable

let numeral_string = string_gen Gen.numeral

let numeral_string_of_size size = string_gen_of_size size Gen.numeral

let list_sum_ f l = List.fold_left (fun acc x-> f x+acc) 0 l

let mk_list a gen =
  let print = Option.map Print.list a.print in
  make ?print gen

let list a = mk_list a (Gen.list a.gen)

let list_of_size size a = mk_list a (Gen.list_size size a.gen)

let small_list a = mk_list a (Gen.small_list a.gen)

let array_sum_ f a = Array.fold_left (fun acc x -> f x+acc) 0 a

let array a =
  make
    ?print:(Option.map Print.array a.print)
    (Gen.array a.gen)

let array_of_size size a =
  make
    ?print:(Option.map Print.array a.print)
    (Gen.array_size size a.gen)

let pair a b =
  make
    ?print:(_opt_map_2 ~f:Print.pair a.print b.print)
    (Gen.pair a.gen b.gen)

let triple a b c =
  make
    ?print:(_opt_map_3 ~f:Print.triple a.print b.print c.print)
    (Gen.triple a.gen b.gen c.gen)

let quad a b c d =
  make
    ?print:(_opt_map_4 ~f:Print.quad a.print b.print c.print d.print)
    (Gen.quad a.gen b.gen c.gen d.gen)

let option a =
  let g = Gen.opt a.gen in
  make
    ?print:(Option.map Print.option a.print)
    g

let map ?print ?collect (f : 'a -> 'b) (a : 'a arbitrary) =
  make
    ?print
    ?collect
    (Gen.map f a.gen)

module Poly_tbl : sig
  type ('a, 'b) t

  val create: 'a Observable.t -> 'b arbitrary -> int -> ('a, 'b) t Gen.t

  val get : ('a, 'b) t -> 'a -> 'b option

  val size : ('b -> int) -> (_, 'b) t -> int

  val print : (_,_) t Print.t
end = struct
  type ('a, 'b) t = {
    get : 'a -> 'b option;
    p_size: ('b -> int) -> int;
    p_print: unit -> string;
  }

  (** TODO This is a bit trickier because the function entries are populated at runtime
      while the shrinking tree must be provided statically and is not mutable ([Seq.t]),
      only the inside tables are.

      We could arguably create a shrinking sequence of fixed size (where the first element is
      a function with no entries) and spread in best-effort entries. Not doing it for now. *)
  let create (type k) (type v) (k : k Observable.t) (v : v arbitrary) (size : int) : (k, v) t Gen.t =
    fun st ->
    let module T = Hashtbl.Make(struct
        type t = k
        let equal = k.Observable.eq
        let hash = k.Observable.hash
      end) in
    (* let tbl_to_list tbl =
     *   T.fold (fun k v l -> (k,v) :: l) tbl []
     * and tbl_of_list l =
     *   let tbl = T.create (max (List.length l) 8) in
     *   List.iter (fun (k,v) -> T.add tbl k v) l;
     *   tbl
     * in *)
    (* make a table
       @param extend if true, extend table on the fly *)
    let (* rec *) make ~extend tbl = {
      get = (fun x ->
          try Some (T.find tbl x)
          with Not_found ->
            if extend then (
              let (Tree.Tree (v, _shrinks)) = v.gen st in
              T.add tbl x v;
              Some v
            ) else None);
      p_print = (fun () -> match v.print with
          | None -> "<fun>"
          | Some pp_v ->
            let b = Buffer.create 64 in
            T.iter
              (fun key value ->
                 Printf.bprintf b "%s -> %s; "
                   (k.Observable.print key) (pp_v value))
              tbl;
            Buffer.contents b);
      (* p_shrink1=(fun yield ->
         Shrink.list (tbl_to_list tbl)
          (fun l ->
             yield (make ~extend:false (tbl_of_list l)))
         );
         p_shrink2=(fun shrink_val yield ->
         (* shrink bindings one by one *)
         T.iter
          (fun x y ->
             shrink_val y
               (fun y' ->
                  let tbl' = T.copy tbl in
                  T.replace tbl' x y';
                  yield (make ~extend:false tbl')))
          tbl); *)
      p_size=(fun size_v -> T.fold (fun _ v n -> n + size_v v) tbl 0);
    } in
    Tree.pure (make ~extend:true (T.create size))

  let get t x = t.get x
  (* let shrink1 t = t.p_shrink1
     let shrink2 p t = t.p_shrink2 p *)
  let print t = t.p_print ()
  let size p t = t.p_size p
end

(** Internal representation of functions *)
type ('a, 'b) fun_repr_tbl = {
  fun_tbl: ('a, 'b) Poly_tbl.t;
  fun_arb: 'b arbitrary;
  fun_default: 'b;
}

type 'f fun_repr =
  | Fun_tbl : ('a, 'ret) fun_repr_tbl -> ('a -> 'ret) fun_repr
  | Fun_map : ('f1 -> 'f2) * 'f1 fun_repr -> 'f2 fun_repr

type _ fun_ =
  | Fun : 'f fun_repr * 'f -> 'f fun_

(** Reifying functions *)
module Fn = struct
  type 'a t = 'a fun_

  let apply (Fun (_,f)) = f

  let make_ (r:_ fun_repr) : _ fun_ =
    let rec call
      : type f. f fun_repr -> f
      = fun r -> match r with
        | Fun_tbl r ->
          begin fun x -> match Poly_tbl.get r.fun_tbl x with
            | None -> r.fun_default
            | Some y -> y
          end
        | Fun_map (g, r') -> g (call r')
    in
    Fun (r, call r)

  let mk_repr tbl arb def =
    Fun_tbl { fun_tbl=tbl; fun_arb=arb; fun_default=def; }

  let map_repr f repr = Fun_map (f,repr)

  let map_fun f (Fun (repr,_)) = make_ (map_repr f repr)

  (* let shrink_rep (r: _ fun_repr): _ Iter.t =
   *   let open Iter in
   *   let rec aux
   *     : type f. f fun_repr Shrink.t
   *     = function
   *       | Fun_tbl {fun_arb=a; fun_tbl=tbl; fun_default=def} ->
   *         let sh_v = match a.shrink with None -> Shrink.nil | Some s->s in
   *         (Poly_tbl.shrink1 tbl >|= fun tbl' -> mk_repr tbl' a def)
   *         <+>
   *           (sh_v def >|= fun def' -> mk_repr tbl a def')
   *         <+>
   *           (Poly_tbl.shrink2 sh_v tbl >|= fun tbl' -> mk_repr tbl' a def)
   *       | Fun_map (g, r') ->
   *         aux r' >|= map_repr g
   *   in
   *   aux r
   * 
   * let shrink (Fun (rep,_)) =
   *   let open Iter in
   *   shrink_rep rep >|= make_ *)

  let print_rep r =
    let buf = Buffer.create 32 in
    let rec aux
      : type f. Buffer.t -> f fun_repr -> unit
      = fun buf r -> match r with
        | Fun_map (_, r') -> aux buf r'
        | Fun_tbl r ->
          Buffer.add_string buf (Poly_tbl.print r.fun_tbl);
          Printf.bprintf buf "_ -> %s" (match r.fun_arb.print with
              | None -> "<opaque>"
              | Some s -> s r.fun_default
            );
    in
    Printf.bprintf buf "{";
    aux buf r;
    Printf.bprintf buf "}";
    Buffer.contents buf

  let print (Fun (rep,_)) = print_rep rep

  let gen_rep (a:_ Observable.t) (b:_ arbitrary): _ fun_repr Gen.t =
    fun st ->
    let Tree.Tree (default_value, _default_value_shrinks) = b.gen st in
    let Tree.Tree (poly_tbl, _poly_tbl_shrinks) = Poly_tbl.create a b 8 st in
    Tree.pure (mk_repr poly_tbl b default_value)

  let gen a b = Gen.map make_ (gen_rep a b)
end

let fun1 o ret =
  make
    (* ~shrink:Fn.shrink *)
    ~print:Fn.print
    (Fn.gen o ret)

module Tuple = struct
  (** heterogeneous list (generic tuple) used to uncurry functions *)
  type 'a t =
    | Nil : unit t
    | Cons : 'a * 'b t -> ('a * 'b) t

  let nil = Nil

  let cons x tail = Cons (x,tail)

  type 'a obs =
    | O_nil : unit obs
    | O_cons : 'a Observable.t * 'b obs -> ('a * 'b) obs

  let o_nil = O_nil

  let o_cons x tail = O_cons (x,tail)

  let rec hash
    : type a. a obs -> a t -> int
    = fun o t -> match o, t with
      | O_nil, Nil -> 42
      | O_cons (o,tail_o), Cons (x, tail) ->
        Observable.H.combine (Observable.hash o x) (hash tail_o tail)

  let rec equal
    : type a. a obs -> a t -> a t -> bool
    = fun o a b -> match o, a, b with
      | O_nil, Nil, Nil -> true
      | O_cons (o, tail_o), Cons (x1, tail1), Cons (x2,tail2) ->
        Observable.equal o x1 x2 &&
        equal tail_o tail1 tail2

  let print o tup =
    let rec aux
      : type a. a obs -> Buffer.t -> a t  -> unit
      = fun o buf t -> match o, t with
        | O_nil, Nil -> Printf.bprintf buf "()"
        | O_cons (o, O_nil), Cons (x,Nil) ->
          Printf.bprintf buf "%s" (Observable.print o x)
        | O_cons (o, tail_o), Cons (x,tail) ->
          Printf.bprintf buf "%s, %a"
            (Observable.print o x) (aux tail_o) tail
    in
    let buf = Buffer.create 64 in
    Buffer.add_string buf "(";
    aux o buf tup;
    Buffer.add_string buf ")";
    Buffer.contents buf

  let observable (o:'a obs) : 'a t Observable.t =
    Observable.make
      ~eq:(equal o)
      ~hash:(hash o)
      (print o)

  let gen (o:'a obs) (ret:'b arbitrary) : ('a t -> 'b) fun_ Gen.t =
    Fn.gen (observable o) ret

  module Infix = struct
    let (@::) x tail = cons x tail
    let (@->) o tail = o_cons o tail
  end
  include Infix
end

let fun_nary (o:_ Tuple.obs) ret : _ arbitrary =
  make
    ~print:Fn.print
    (Tuple.gen o ret)

let fun2 o1 o2 ret =
  let open Tuple in
  map
    (Fn.map_fun (fun g x y -> g (x @:: y @:: nil)))
    (fun_nary (o1 @-> o2 @-> o_nil) ret)

let fun3 o1 o2 o3 ret =
  let open Tuple in
  map
    (Fn.map_fun (fun g x y z -> g (x @:: y @:: z @:: nil)))
    (fun_nary (o1 @-> o2 @-> o3 @-> o_nil) ret)

let fun4 o1 o2 o3 o4 ret =
  let open Tuple in
  map
    (Fn.map_fun (fun g x y z w -> g (x @:: y @:: z @:: w @:: nil)))
    (fun_nary (o1 @-> o2 @-> o3 @-> o4 @-> o_nil) ret)

(* Generator combinators *)

(** given a list, returns generator that picks at random from list *)
let oneofl ?print ?collect xs = make ?print ?collect (Gen.oneofl xs)

let oneofa ?print ?collect xs = make ?print ?collect (Gen.oneofa xs)

(** Given a list of generators, returns generator that randomly uses one of the generators
    from the list *)
let oneof (l : 'a arbitrary list) : 'a arbitrary =
  let gens = List.map (fun a -> a.gen) l in
  let {print; collect; _} = List.hd l in
  make ?print ?collect (Gen.oneof gens)

(** Generator that always returns given value *)
let always ?print x = make ?print (Gen.pure x)

(** like oneof, but with weights *)
let frequency ?print ?collect (l : (int * 'a arbitrary) list) : 'a arbitrary =
  let first = snd (List.hd l) in
  let print = _opt_sum print first.print in
  let collect = _opt_sum collect first.collect in
  let gens = List.map (fun (x,y) -> x, y.gen) l in
  make ?print ?collect (Gen.frequency gens)

(** Given list of [(frequency,value)] pairs, returns value with probability proportional
    to given frequency *)
let frequencyl ?print l = make ?print (Gen.frequencyl l)

let frequencya ?print l = make ?print (Gen.frequencya l)

let map_same_type (f : 'a -> 'a) (arb : 'a arbitrary) : 'a arbitrary =
  {arb with gen = Gen.map f arb.gen}

module TestResult = struct
  type 'a counter_ex = {
    instance: 'a; (** The counter-example(s) *)
    shrink_steps: int; (** How many shrinking steps for this counterex *)
    msg_l: string list; (** messages. @since 0.7 *)
  }

  (** Result state.
      changed in 0.10 (move to inline records) *)
  type 'a state =
    | Success
    | Failed of {
        instances: 'a counter_ex list; (** Failed instance(s) *)
      }
    | Failed_other of {msg: string}
    | Error of {
        instance: 'a counter_ex;
        exn: exn;
        backtrace: string;
      } (** Error, backtrace, and instance that triggered it *)


  (* result returned by running a test *)
  type 'a t = {
    mutable state : 'a state;
    mutable count: int;  (* number of tests *)
    mutable count_gen: int; (* number of generated cases *)
    collect_tbl: (string, int) Hashtbl.t lazy_t;
    stats_tbl: ('a stat * (int, int) Hashtbl.t) list;
    mutable warnings: string list;
    mutable instances: 'a list;
  }

  let get_count {count; _} = count

  let get_count_gen {count_gen; _} = count_gen

  let get_state {state; _} = state

  (* indicate failure on the given [instance] *)
  let fail ~msg_l ~steps:shrink_steps res instance =
    let c_ex = {instance; shrink_steps; msg_l; } in
    match res.state with
    | Success -> res.state <- Failed {instances=[ c_ex ]}
    | Error _
    | Failed_other _ -> ()
    | Failed {instances=[]} -> assert false
    | Failed {instances=l} -> res.state <- Failed {instances=c_ex :: l}

  let error ~msg_l ~steps res instance exn backtrace =
    res.state <- Error {instance={instance; shrink_steps=steps; msg_l; }; exn; backtrace}

  let collect r =
    if Lazy.is_val r.collect_tbl then Some (Lazy.force r.collect_tbl) else None

  let stats r = r.stats_tbl
  let warnings r = r.warnings

  let is_success r = match r.state with
    | Success -> true
    | Failed _ | Error _ | Failed_other _ -> false
end

module Test = struct
  type 'a cell = {
    count : int; (* number of tests to do *)
    long_factor : int; (* multiplicative factor for long test count *)
    max_gen : int; (* max number of instances to generate (>= count) *)
    max_fail : int; (* max number of failures *)
    law : 'a -> bool; (* the law to check *)
    arb : 'a arbitrary; (* how to generate/print/shrink instances *)
    if_assumptions_fail: [`Fatal | `Warning] * float;
    mutable name : string; (* name of the law *)
  }

  type t = | Test : 'a cell -> t

  let get_name {name; _} = name

  let set_name c name = c.name <- name

  let get_law {law; _} = law

  let get_arbitrary {arb; _} = arb

  let get_count {count; _ } = count

  let get_long_factor {long_factor; _} = long_factor

  let default_count = 100

  let fresh_name =
    let r = ref 0 in
    (fun () -> incr r; Printf.sprintf "anon_test_%d" !r)

  let default_if_assumptions_fail = `Warning, 0.05

  let make_cell ?(if_assumptions_fail=default_if_assumptions_fail)
      ?(count=default_count) ?(long_factor=1) ?max_gen
      ?(max_fail=1) ?(name=fresh_name()) arb law
    =
    let max_gen = match max_gen with None -> count + 200 | Some x->x in
    {
      law;
      arb;
      max_gen;
      max_fail;
      name;
      count;
      long_factor;
      if_assumptions_fail;
    }

  let make ?if_assumptions_fail ?count ?long_factor ?max_gen ?max_fail ?name arb law =
    Test (make_cell ?if_assumptions_fail ?count ?long_factor ?max_gen ?max_fail ?name arb law)

  (** {6 Running the test} *)

  module R = TestResult

  (* Result of an instance run *)
  type res =
    | Success
    | Failure
    | FalseAssumption
    | Error of exn * string

  (* Step function, called after each instance test *)
  type 'a step = string -> 'a cell -> 'a -> res -> unit

  let step_nil_ _ _ _ _ = ()

  (* Events of a test *)
  type 'a event =
    | Generating
    | Collecting of 'a
    | Testing of 'a
    | Shrunk of int * 'a
    | Shrinking of int * int * 'a

  type 'a handler = string -> 'a cell -> 'a event -> unit

  let handler_nil_ _ _ _ = ()

  (* state required by {!check} to execute *)
  type 'a state = {
    test: 'a cell;
    step: 'a step;
    handler : 'a handler;
    rand: Random.State.t;
    mutable res: 'a TestResult.t;
    mutable cur_count: int;  (** number of iterations remaining to do *)
    mutable cur_max_gen: int; (** maximum number of generations allowed *)
    mutable cur_max_fail: int; (** maximum number of counter-examples allowed *)
  }

  let is_done state = state.cur_count <= 0 || state.cur_max_gen <= 0

  let decr_count state =
    state.res.R.count <- state.res.R.count + 1;
    state.cur_count <- state.cur_count - 1

  let new_input_tree state =
    state.res.R.count_gen <- state.res.R.count_gen + 1;
    state.cur_max_gen <- state.cur_max_gen - 1;
    state.test.arb.gen state.rand

  (* statistics on inputs *)
  let collect st i = match st.test.arb.collect with
    | None -> ()
    | Some f ->
      let key = f i in
      let (lazy tbl) = st.res.R.collect_tbl in
      let n = try Hashtbl.find tbl key with Not_found -> 0 in
      Hashtbl.replace tbl key (n+1)

  let update_stats st i =
    List.iter
      (fun ((_,f), tbl) ->
         let key = f i in
         let n = try Hashtbl.find tbl key with Not_found -> 0 in
         Hashtbl.replace tbl key (n+1))
      st.res.R.stats_tbl

  type res_or_exn =
    | Shrink_fail
    | Shrink_exn of exn

  (* triggered by user to fail with a message *)
  exception User_fail of string

  let fail_report m = raise (User_fail m)

  let fail_reportf m =
    let buf = Buffer.create 64 in
    Format.kfprintf
      (fun out -> Format.fprintf out "@?"; fail_report (Buffer.contents buf))
      (Format.formatter_of_buffer buf) m

  type 'a run_res =
    | Run_ok
    | Run_fail of string list

  let run_law law x =
    try
      if law x then Run_ok else Run_fail []
    with User_fail msg -> Run_fail [msg]

  (* try to shrink counter-ex [i] into a smaller one. Returns
     shrinked value and number of steps *)
  let shrink st (i_tree : 'a Tree.t) (r : res_or_exn) m : 'a * res_or_exn * string list * int =
    let is_err = match r with
      | Shrink_exn _ -> true | _ -> false
    in
    let rec shrink_ st i_tree r m ~steps =
      let Tree.Tree (i, shrinks) = i_tree in
      st.handler st.test.name st.test (Shrunk (steps, i));
      let count = ref 0 in
      let i' = Seq.filter_map
          (fun x_tree ->
             let Tree.Tree (x, _) = x_tree in
             try
               incr count;
               st.handler st.test.name st.test (Shrinking (steps, !count, x));
               begin match run_law st.test.law x with
                 | Run_fail m when not is_err -> Some (x_tree, Shrink_fail, m)
                 | _ -> None
               end
             with
             | Failed_precondition | No_example_found _ -> None
             | e when is_err -> Some (x_tree, Shrink_exn e, []) (* fail test (by error) *)
          ) shrinks
               |> Seq.hd
      in
      match i' with
      | None -> i, r, m, steps
      | Some (i_tree',r',m') -> shrink_ st i_tree' r' m' ~steps:(steps + 1) (* shrink further *)
    in
    shrink_ ~steps:0 st i_tree r m

  type 'a check_result =
    | CR_continue
    | CR_yield of 'a TestResult.t

  (* test raised [e] on [input]; try to shrink then fail *)
  let handle_exn state input e bt : _ check_result =
    (* first, shrink
       TODO: shall we shrink differently (i.e. expected only an error)? *)
    let input, r, msg_l, steps = shrink state input (Shrink_exn e) [] in
    (* recover exception of shrunk input *)
    let e = match r with
      | Shrink_fail -> e
      | Shrink_exn e' -> e'
    in
    state.step state.test.name state.test input (Error (e, bt));
    R.error state.res ~steps ~msg_l input e bt;
    CR_yield state.res

  (* test failed on [input], which means the law is wrong. Continue if
     we should. *)
  let handle_fail state input msg_l : _ check_result =
    (* first, shrink *)
    let input, _, msg_l, steps = shrink state input Shrink_fail msg_l in
    (* fail *)
    decr_count state;
    state.step state.test.name state.test input Failure;
    state.cur_max_fail <- state.cur_max_fail - 1;
    R.fail state.res ~steps ~msg_l input;
    CR_yield state.res

  (* [check_state state] applies [state.test] repeatedly ([iter] times)
      on output of [test.rand], and if [state.test] ever returns false,
      then the input that caused the failure is returned in [Failed].
      If [func input] raises [Failed_precondition] then  the input is discarded, unless
         max_gen is 0. *)
  let rec check_state state : _ R.t =
    if is_done state then state.res
    else (
      state.handler state.test.name state.test Generating;
      match new_input_tree state with
      | i_tree ->
        check_state_input state i_tree
      | exception e ->
        (* turn it into an error *)
        let bt = Printexc.get_backtrace() in
        let msg =
          Printf.sprintf
            "ERROR: uncaught exception in generator for test %s after %d steps:\nException: %s\nBacktrace: %s"
            state.test.name state.test.count (Printexc.to_string e) bt
        in
        state.res.R.state <- R.Failed_other {msg};
        state.res
    )
  and check_state_input state input_tree =
    let Tree.Tree (input, _) = input_tree in
    state.handler state.test.name state.test (Collecting input);
    state.res.R.instances <- input :: state.res.R.instances;
    collect state input;
    update_stats state input;
    let res =
      try
        state.handler state.test.name state.test (Testing input);
        begin match run_law state.test.law input with
          | Run_ok ->
            (* one test ok *)
            decr_count state;
            state.step state.test.name state.test input Success;
            CR_continue
          | Run_fail msg_l ->
            handle_fail state input_tree msg_l
        end
      with
      | Failed_precondition | No_example_found _ ->
        state.step state.test.name state.test input FalseAssumption;
        CR_continue
      | e ->
        let bt = Printexc.get_backtrace () in
        handle_exn state input_tree e bt
    in
    match res with
    | CR_continue -> check_state state
    | CR_yield x -> x

  type 'a callback = string -> 'a cell -> 'a TestResult.t -> unit

  let callback_nil_ : _ callback = fun _ _ _ -> ()

  (* check that there are sufficiently many tests which passed, to avoid
     the case where they all passed by failed precondition *)
  let check_if_assumptions target_count cell res : unit =
    let percentage_of_count = float_of_int res.R.count /. float_of_int target_count in
    let assm_flag, assm_frac = cell.if_assumptions_fail in
    if R.is_success res && percentage_of_count < assm_frac then (
      let msg =
        format_of_string "%s: \
                          only %.1f%% tests (of %d) passed precondition for %S\n\n\
                          NOTE: it is likely that the precondition is too strong, or that \
                          the generator is buggy.\n%!"
      in
      match assm_flag with
      | `Warning ->
        let msg = Printf.sprintf
            msg "WARNING"
            (percentage_of_count *. 100.) cell.count cell.name in
        res.R.warnings <- msg :: res.R.warnings
      | `Fatal ->
        (* turn it into an error *)
        let msg = Printf.sprintf
            msg "ERROR"
            (percentage_of_count *. 100.) cell.count cell.name in
        res.R.state <- R.Failed_other {msg}
    )

  (* main checking function *)
  let check_cell ?(long=false) ?(call=callback_nil_)
      ?(step=step_nil_) ?(handler=handler_nil_)
      ?(rand=Random.State.make [| 0 |]) cell =
    let factor = if long then cell.long_factor else 1 in
    let target_count = factor*cell.count in
    let state = {
      test=cell; rand;
      step; handler;
      cur_count=target_count;
      cur_max_gen=factor*cell.max_gen;
      cur_max_fail=factor*cell.max_fail;
      res = {R.
              state=R.Success; count=0; count_gen=0;
              collect_tbl=lazy (Hashtbl.create 10);
              instances=[]; warnings=[];
              stats_tbl= List.map (fun stat -> stat, Hashtbl.create 10) cell.arb.stats;
            };
    } in
    let res = check_state state in
    check_if_assumptions target_count cell res;
    call cell.name cell res;
    res

  exception Test_fail of string * string list
  exception Test_error of string * string * exn * string

  (* print instance using [arb] *)
  let print_instance arb i = match arb.print with
    | None -> "<instance>"
    | Some pp -> pp i

  let print_c_ex arb c : string =
    let buf = Buffer.create 64 in
    begin
      if c.R.shrink_steps > 0
      then Printf.bprintf buf "%s (after %d shrink steps)"
          (print_instance arb c.R.instance) c.R.shrink_steps
      else Buffer.add_string buf (print_instance arb c.R.instance)
    end;
    List.iter
      (fun msg ->
         Buffer.add_char buf '\n';
         Buffer.add_string buf msg;
         Buffer.add_char buf '\n')
      c.R.msg_l;
    Buffer.contents buf

  let pp_print_test_fail name out l =
    let rec pp_list out = function
      | [] -> ()
      | [x] -> Format.fprintf out "%s@," x
      | x :: y -> Format.fprintf out "%s@,%a" x pp_list y
    in
    Format.fprintf out "@[test `%s`@ failed on ≥ %d cases:@ @[<v>%a@]@]"
      name (List.length l) pp_list l

  let asprintf fmt =
    let buf = Buffer.create 128 in
    let out = Format.formatter_of_buffer buf in
    Format.kfprintf (fun _ -> Buffer.contents buf) out fmt

  let print_test_fail name l = asprintf "@[%a@]@?" (pp_print_test_fail name) l

  let print_test_error name i e stack =
    Format.sprintf "@[test `%s`@ raised exception `%s`@ on `%s`@,%s@]"
      name (Printexc.to_string e) i stack

  let print_collect c =
    let out = Buffer.create 64 in
    Hashtbl.iter
      (fun case num -> Printf.bprintf out "%s: %d cases\n" case num) c;
    Buffer.contents out

  let stat_max_lines = 20 (* maximum number of lines for a histogram *)

  let print_stat ((name,_), tbl) =
    let avg = ref 0. in
    let num = ref 0 in
    let min_idx, max_idx =
      Hashtbl.fold
        (fun i res (m1,m2) ->
           avg := !avg +. float_of_int (i * res);
           num := !num + res;
           min i m1, max i m2)
        tbl (max_int,min_int)
    in
    (* compute average *)
    if !num > 0 then (
      avg := !avg /. float_of_int !num
    );
    (* compute std-dev: sqroot of sum of squared distance-to-average
       https://en.wikipedia.org/wiki/Standard_deviation *)
    let stddev =
      Hashtbl.fold
        (fun i res m -> m +. (float_of_int i -. !avg) ** 2. *. float_of_int res)
        tbl 0.
      |> (fun s -> if !num>0 then s /. float_of_int !num else s)
      |> sqrt
    in
    (* compute median *)
    let median = ref 0 in
    let median_num = ref 0 in (* how many values have we seen yet? once >= !n/2 we set median *)
    (Hashtbl.fold (fun i cnt acc -> (i,cnt)::acc) tbl [])
    |> List.sort (fun (i,_) (j,_) -> poly_compare i j)
    |> List.iter
      (fun (i,cnt) ->
         if !median_num < !num/2 then (
           median_num := !median_num + cnt;
           (* just went above median! *)
           if !median_num >= !num/2 then
             median := i));
    (* group by buckets, if there are too many entries: *)
    (* first compute histogram and bucket size *)
    let hist_size, bucket_size =
      let sample_width = Int64.(sub (of_int max_idx) (of_int min_idx)) in
      if sample_width > Int64.of_int stat_max_lines
      then stat_max_lines,
           int_of_float (ceil (Int64.to_float sample_width /. float_of_int stat_max_lines))
      else max_idx-min_idx, 1
    in
    let hist_size = if min_idx + bucket_size * hist_size <= max_idx then 1+hist_size else hist_size in
    (* accumulate bucket counts *)
    let max_val = ref 0 in (* max value after grouping by buckets *)
    let bucket_count = Array.init hist_size (fun _ -> 0) in
    Hashtbl.iter
      (fun j count ->
         let bucket = Int64.(to_int (div (sub (of_int j) (of_int min_idx)) (of_int bucket_size))) in
         let new_count = bucket_count.(bucket) + count in
         bucket_count.(bucket) <- new_count;
         max_val := max !max_val new_count) tbl;
    (* print entries of the table, sorted by increasing index *)
    let out = Buffer.create 128 in
    Printf.bprintf out "stats %s:\n" name;
    Printf.bprintf out
      "  num: %d, avg: %.2f, stddev: %.2f, median %d, min %d, max %d\n"
      !num !avg stddev !median min_idx max_idx;
    let indwidth =
      max (String.length (Printf.sprintf "%d" min_idx))
        (max (String.length (Printf.sprintf "%d" max_idx))
           (String.length (Printf.sprintf "%d" (min_idx + bucket_size * hist_size)))) in
    let labwidth = if bucket_size=1 then indwidth else 2+2*indwidth in
    for i = 0 to hist_size - 1 do
      let i' = min_idx + i * bucket_size in
      let blabel =
        if bucket_size=1
        then Printf.sprintf "%*d" indwidth i'
        else
          let bucket_bound = i'+bucket_size-1 in
          Printf.sprintf "%*d..%*d" indwidth i' indwidth (if bucket_bound < i' then max_int else bucket_bound) in
      let bcount = bucket_count.(i) in
      (* NOTE: keep in sync *)
      let bar_len = bcount * 55 / !max_val in
      Printf.bprintf out "  %*s: %-56s %10d\n" labwidth blabel (String.make bar_len '#') bcount
    done;
    Buffer.contents out

  let () = Printexc.register_printer
      (function
        | Test_fail (name,l) -> Some (print_test_fail name l)
        | Test_error (name,i,e,st) -> Some (print_test_error name i e st)
        | User_fail s -> Some ("qcheck: user fail:\n" ^ s)
        | _ -> None)

  let print_fail arb name l =
    print_test_fail name (List.map (print_c_ex arb) l)

  let print_fail_other name ~msg =
    print_test_fail name [msg]

  let print_error ?(st="") arb name (i,e) =
    print_test_error name (print_c_ex arb i) e st

  let check_result cell res = match res.R.state with
    | R.Success -> ()
    | R.Error {instance; exn; backtrace} ->
      raise (Test_error (cell.name, print_c_ex cell.arb instance, exn, backtrace))
    | R.Failed {instances=l} ->
      let l = List.map (print_c_ex cell.arb) l in
      raise (Test_fail (cell.name, l))
    | R.Failed_other {msg} ->
      raise (Test_fail (cell.name, [msg]))

  let check_cell_exn ?long ?call ?step ?rand cell =
    let res = check_cell ?long ?call ?step ?rand cell in
    check_result cell res

  let check_exn ?long ?rand (Test cell) = check_cell_exn ?long ?rand cell
end

let find_example ?(name : string = "<example>") ?(count : int option) ~(f : 'a -> bool) (gen : 'a Gen.t) : 'a Gen.t =
  (* the random generator of examples satisfying [f]. To do that we
     test the property [fun x -> not (f x)]; any counter-example *)
  let gen st =
    let cell =
      let arb = make gen in
      Test.make_cell ~max_fail:1 ?count arb (fun x -> not (f x))
    in
    let res = Test.check_cell ~rand:st cell in
    begin match res.TestResult.state with
      | TestResult.Success -> raise (No_example_found name)
      | TestResult.Error _ -> raise (No_example_found name)
      | TestResult.Failed {instances=[]} -> assert false
      | TestResult.Failed {instances=failed::_} ->
        (* found counter-example! *)
        Tree.pure failed.TestResult.instance
      | TestResult.Failed_other {msg=_} ->
        raise (No_example_found name)

    end
  in
  gen

let find_example_gen ?(rand : Random.State.t option) ?(name : string option) ?(count : int option) ~(f : 'a -> bool) (gen : 'a Gen.t) : 'a =
  let g = find_example ?name ?count ~f gen in
  Gen.generate1 ?rand g

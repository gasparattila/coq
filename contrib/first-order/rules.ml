(***********************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team    *)
(* <O___,, *        INRIA-Rocquencourt  &  LRI-CNRS-Orsay              *)
(*   \VV/  *************************************************************)
(*    //   *      This file is distributed under the terms of the      *)
(*         *       GNU Lesser General Public License Version 2.1       *)
(***********************************************************************)

(* $Id$ *)

open Util
open Names
open Term
open Tacmach
open Tactics
open Tacticals
open Termops
open Reductionops
open Declarations
open Formula
open Sequent
open Libnames

type seqtac= (Sequent.t -> tactic) -> Sequent.t -> tactic

type lseqtac= global_reference -> seqtac

let wrap n b tacrec seq gls=
  check_for_interrupt ();
  let nc=pf_hyps gls in
  let env=pf_env gls in
  let rec aux i nc ctx=
    if i<=0 then seq else 
      match nc with
	  []->anomaly "Not the expected number of hyps"
	| ((id,_,typ) as nd)::q->  
	    if occur_var env id (pf_concl gls) || 
	      List.exists (occur_var_in_decl env id) ctx then
		(aux (i-1) q (nd::ctx))
	    else
	      add_left (VarRef id,typ) (aux (i-1) q (nd::ctx)) true gls in
  let seq1=aux n nc [] in
  let seq2=if b then change_right (pf_concl gls) seq1 gls else seq1 in
    tacrec seq2 gls

let id_of_global=function
    VarRef id->id
  | _->assert false

let clear_global=function
    VarRef id->clear [id]
  | _->tclIDTAC
      

(* connection rules *)

let axiom_tac t seq=
  try exact_no_check (constr_of_reference (find_left t seq)) 
  with Not_found->tclFAIL 0 "No axiom link" 

let ll_atom_tac a id tacrec seq=
  try 
    tclTHENLIST
      [generalize [mkApp(constr_of_reference id,
			 [|constr_of_reference (find_left a seq)|])];
       clear_global id;
       intro;
       wrap 1 false tacrec seq] 
  with Not_found->tclFAIL 0 "No link" 

(* evaluation rules *)

let evaluable_tac ec tacrec seq gl=
  tclTHEN
    (unfold_in_concl [[1],ec]) 
    (wrap 0 true tacrec seq) gl

let left_evaluable_tac ec id tacrec seq gl=
  tclTHENLIST
    [generalize [constr_of_reference id];
     clear_global id;
     intro;
     (fun gls->
	let nid=(Tacmach.pf_nth_hyp_id gls 1) in
	  unfold_in_hyp [[1],ec] (Tacexpr.InHypType nid) gls);
     wrap 1 false tacrec seq] gl

(* right connectives rules *)

let and_tac tacrec seq=
  tclTHEN simplest_split (wrap 0 true tacrec seq)

let or_tac tacrec seq=
  any_constructor (Some (tclSOLVE [wrap 0 true tacrec seq]))

let arrow_tac tacrec seq=
  tclTHEN intro (wrap 1 true tacrec seq)
   
(* left connectives rules *)

let left_and_tac ind id tacrec seq=
  let n=(construct_nhyps ind).(0) in  
    tclTHENLIST 
      [simplest_elim (constr_of_reference id);
       clear_global id; 
       tclDO n intro;
       wrap n false tacrec seq]

let left_or_tac ind id tacrec seq=
  let v=construct_nhyps ind in  
  let f n=
    tclTHENLIST
      [clear_global id;
       tclDO n intro;
       wrap n false tacrec seq] in
    tclTHENSV
      (simplest_elim (constr_of_reference id))
      (Array.map f v)

let left_false_tac id=
  simplest_elim (constr_of_reference id)

(* left arrow connective rules *)

(* We use this function for false, and, or, exists *)

let ll_ind_tac ind largs id tacrec seq gl= 
  (try
     let rcs=ind_hyps 0 ind largs in
     let vargs=Array.of_list largs in
	     (* construire le terme  H->B, le generaliser etc *)   
     let myterm i=
       let rc=rcs.(i) in
       let p=List.length rc in
       let cstr=mkApp ((mkConstruct (ind,(i+1))),vargs) in
       let vars=Array.init p (fun j->mkRel (p-j)) in
       let capply=mkApp ((lift p cstr),vars) in
       let head=mkApp ((lift p (constr_of_reference id)),[|capply|]) in
	 Sign.it_mkLambda_or_LetIn head rc in
       let lp=Array.length rcs in
       let newhyps=list_tabulate myterm lp in
	 tclTHENLIST 
	   [generalize newhyps;
	    clear_global id;
	    tclDO lp intro;
	    wrap lp false tacrec seq]
   with Invalid_argument _ ->tclFAIL 0 "") gl

let ll_arrow_tac a b c id tacrec seq=
  let cc=mkProd(Anonymous,a,(lift 1 b)) in
  let d=mkLambda (Anonymous,b,
		  mkApp ((constr_of_reference id),
			 [|mkLambda (Anonymous,(lift 1 a),(mkRel 2))|])) in
    tclTHENS (cut c)
      [tclTHENLIST
	 [intro;
	  clear_global id;
	  wrap 1 false tacrec seq];
       tclTHENS (cut cc) 
         [exact_no_check (constr_of_reference id); 
	  tclTHENLIST 
	    [generalize [d];
	     intro;
	     clear_global id;
	     tclSOLVE [wrap 1 true tacrec seq]]]]

(* quantifier rules (easy side) *)

let forall_tac tacrec seq=
  tclTHEN intro (wrap 0 true tacrec seq)

let left_exists_tac ind id tacrec seq=
  let n=(construct_nhyps ind).(0) in  
    tclTHENLIST
      [simplest_elim (constr_of_reference id);
       clear_global id;
       tclDO n intro;
       (wrap (n-1) false tacrec seq)]

let ll_forall_tac prod id tacrec seq=
  tclTHENS (cut prod)
    [tclTHENLIST
       [intro;
	(fun gls->
	   let id0=pf_nth_hyp_id gls 1 in
	   let term=mkApp((constr_of_reference id),[|mkVar(id0)|]) in
	     tclTHEN (generalize [term]) (clear [id0]) gls);  
	clear_global id;
	intro;
	tclSOLVE [wrap 1 false tacrec (deepen seq)]];
     tclSOLVE [wrap 0 true tacrec (deepen seq)]]

(* complicated stuff for instantiation with unification *)

(* moved to instances.ml *)

(* special for compatibility with old Intuition *)

let constant str = Coqlib.gen_constant "User" ["Init";"Logic"] str

let defined_connectives=lazy
  [[],EvalConstRef (destConst (constant "not"));
   [],EvalConstRef (destConst (constant "iff"))]

let normalize_evaluables=
  onAllClauses
    (function 
	 None->unfold_in_concl (Lazy.force defined_connectives)
       | Some id-> 
	   unfold_in_hyp (Lazy.force defined_connectives) 
	   (Tacexpr.InHypType id))

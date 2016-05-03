Require Import Prog.
Require Import Log.
Require Import BFile.
Require Import Word.
Require Import Omega.
Require Import BasicProg.
Require Import Bool.
Require Import Pred PredCrash.
Require Import DirName.
Require Import Hoare.
Require Import GenSepN.
Require Import ListPred.
Require Import SepAuto.
Require Import Idempotent.
Require Import Inode.
Require Import List ListUtils.
Require Import Balloc.
Require Import Bytes.
Require Import DirTree.
Require Import Rec.
Require Import Arith.
Require Import Array.
Require Import FSLayout.
Require Import Cache.
Require Import Errno.
Require Import AsyncDisk.
Require Import GroupLog.
Require Import SuperBlock.
Require Import NEList.
Require Import AsyncFS.
Require Import DirUtil.
Require Import String.


Import ListNotations.

Set Implicit Arguments.

(**
 * Atomic copy: create a copy of file [src_fn] in the root directory [the_dnum],
 * with the new file name [dst_fn].
 *
 *)



Module ATOMICCP.

  Definition temp_fn := ".temp"%string.
  
  (** Programs **)

  (* copy an existing src into an existing, empty dst. *)

  Definition copydata T fsxp src_inum dst_inum mscs rx : prog T :=
    let^ (mscs, attr) <-  AFS.file_get_attr fsxp src_inum mscs;
    let^ (mscs, b) <- AFS.read_fblock fsxp src_inum 0 mscs;
    let^ (mscs) <- AFS.update_fblock_d fsxp dst_inum 0 b mscs;
    let^ (mscs, ok) <- AFS.file_set_attr fsxp dst_inum attr mscs;
    let^ (mscs) <- AFS.file_sync fsxp dst_inum mscs;    (* we want a metadata and data sync here *)
    rx ^(mscs, ok).

  Definition copy2temp T fsxp src_inum dst_inum mscs rx : prog T :=
    let^ (mscs, ok) <- AFS.file_truncate fsxp dst_inum 1 mscs;  (* XXX type error when passing sz *)
    If (bool_dec ok true) {
      let^ (mscs, ok) <- copydata fsxp src_inum dst_inum mscs;
      rx ^(mscs, ok)
    } else {
      let^ (mscs) <- AFS.file_sync fsxp dst_inum mscs;    (* do a sync to simplify spec *)
      rx ^(mscs, ok)
    }.

  Definition copy_and_rename T fsxp src_inum dst_inum dst_fn mscs rx : prog T :=
    let^ (mscs, ok) <- copy2temp fsxp src_inum dst_inum mscs;
    match ok with
      | false =>
          rx ^(mscs, false)
      | true =>
        let^ (mscs, ok1) <- AFS.rename fsxp the_dnum [] temp_fn [] dst_fn mscs;
        let^ (mscs) <- AFS.tree_sync fsxp mscs;
        rx ^(mscs, ok1)
    end.

  Definition atomic_cp T fsxp src_inum dst_fn mscs rx : prog T :=
    let^ (mscs, maybe_dst_inum) <- AFS.create fsxp the_dnum temp_fn mscs;
    match maybe_dst_inum with
      | None => rx ^(mscs, false)
      | Some dst_inum =>
        let^ (mscs, ok) <- copy_and_rename fsxp src_inum dst_inum dst_fn mscs;
        rx ^(mscs, ok)
    end.

  (** recovery programs **)

  (* atomic_cp recovery: if temp_fn exists, delete it *)
  Definition cleanup {T} fsxp mscs rx : prog T :=
    let^ (mscs, maybe_src_inum) <- AFS.lookup fsxp the_dnum [temp_fn] mscs;
    match maybe_src_inum with
    | None => rx mscs
    | Some (src_inum, isdir) =>
      let^ (mscs, ok) <- AFS.delete fsxp the_dnum temp_fn mscs;
      let^ (mscs) <- AFS.tree_sync fsxp mscs;
      rx mscs
    end.

  (* top-level recovery function: call AFS recover and then atomic_cp's recovery *)
  Definition recover {T} rx : prog T :=
    let^ (mscs, fsxp) <- AFS.recover;
    mscs <- cleanup fsxp mscs;
    rx ^(mscs, fsxp).


  (** Specs and proofs **)

  Opaque LOG.idempred.
  Opaque crash_xform.

  Lemma arrayN_one: forall V (v:V),
      0 |-> v <=p=> arrayN 0 [v].
  Proof.
    split; cancel.
  Qed.

  Lemma arrayN_ex_one: forall V (l : list V),
      List.length l = 1 ->
      arrayN_ex l 0 <=p=> emp.
  Proof.
    destruct l.
    simpl; intros.
    congruence.
    destruct l.
    simpl. intros.
    unfold arrayN_ex.
    simpl.
    split; cancel.
    simpl. intros.
    congruence.
  Qed.

  Ltac xcrash_norm :=  repeat (xform_norm; cancel).

  Theorem copydata_ok : forall fsxp src_inum tinum mscs,
    {< ds Fm Ftop temp_tree src_fn file tfile v0 t0,
    PRE:hm  LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) mscs hm * 
      [[[ ds!! ::: (Fm * DIRTREE.rep fsxp Ftop temp_tree) ]]] *
      [[ DIRTREE.find_subtree [src_fn] temp_tree = Some (DIRTREE.TreeFile src_inum file) ]] *
      [[ DIRTREE.find_subtree [temp_fn] temp_tree = Some (DIRTREE.TreeFile tinum tfile) ]] *
      [[ src_fn <> temp_fn ]] *
      [[[ BFILE.BFData file ::: (0 |-> v0) ]]] *
      [[[ BFILE.BFData tfile ::: (0 |-> t0) ]]]
    POST:hm' RET:^(mscs, r)
      exists d tree' f', 
        LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
        [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
        ([[ r = false]] * 
         [[ tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum (BFILE.synced_file f')) temp_tree ]]
        \/ 
         [[ r = true ]] *
         [[ tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum (BFILE.synced_file file)) temp_tree ]])
    XCRASH:hm'
      exists dlist,
        [[ Forall (fun d => (exists tree' tfile', (Fm * DIRTREE.rep fsxp Ftop tree')%pred (list2nmem d) /\
             tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum tfile') temp_tree)) %type dlist ]] *
        ( (* crashed before flushing *)
          LOG.idempred (FSXPLog fsxp) (SB.rep fsxp) (pushdlist dlist ds) hm' \/
          (exists d dlist', [[dlist = d :: dlist' ]] * 
            (* crashed after a flush operation  *)
            (LOG.idempred (FSXPLog fsxp) (SB.rep fsxp) (d, dlist') hm')))
     >} copydata fsxp src_inum tinum mscs.
  Proof.
    unfold copydata; intros.
    step.
    step.
    step.

    Focus 2.  (* update_fblock_d crash condition *)
    AFS.xcrash_solve.
    xform_norm; cancel.
    xform_norm. safecancel.
    xcrash_norm.
    instantiate (x := nil).
    or_l.
    simpl.
    cancel.
    apply Forall_nil.
    xcrash_norm.  (* right branch of or *)
    or_r.
    xcrash_norm.
    eapply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply.
    cancel.
    apply Forall_nil.

    step.  (* setattr *)

    Focus 2.  (* setattr failed crash condition*)
    AFS.xcrash_solve.
    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply.
    cancel.
    apply Forall_nil.
   
    step. (* file_sync *)
    step. (* return *)
    
    (* postcondition, setattr failed *)
    or_l.
    cancel.
    erewrite update_update_subtree_eq.
    f_equal.

    (* setattr success crash condition: two cases *)
    (* left or case *)
    AFS.xcrash_solve.
    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply.
    cancel.
    apply Forall_nil.
    (* right or case *)
    AFS.xcrash_solve.
    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply.
    erewrite update_update_subtree_eq.
    cancel.
    apply Forall_nil.

    (* postcondition, success *)
    step.
    or_r.
    safecancel.
    erewrite update_update_subtree_eq.
    erewrite update_update_subtree_eq.
    f_equal.
    apply arrayN_one in H5.
    apply list2nmem_array_eq in H5.
    apply arrayN_one in H16.
    apply list2nmem_array_eq in H16.
    destruct file.
    rewrite H16.
    simpl in H5.
    rewrite H5.
    f_equal.

    AFS.xcrash_solve.  (* crash condition file_sync *)
    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    simpl.
    pred_apply.
    cancel.
    simpl.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply.
    erewrite update_update_subtree_eq.
    cancel.
    apply Forall_nil.

    AFS.xcrash_solve. (* crash condition file_sync or right *)
    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply.
    cancel.
    erewrite update_update_subtree_eq.
    erewrite update_update_subtree_eq.
    cancel.
    apply Forall_nil.
    
    AFS.xcrash_solve.  (* crash condition read_fblock *)
    repeat (xform_norm; cancel).
    or_l.
    instantiate (x := []); simpl.
    cancel.
    apply Forall_nil.

    AFS.xcrash_solve.  (* crash condition file_get_attr *)
    repeat (xform_norm; cancel).
    or_l.
    instantiate (x := nil); simpl.
    cancel.
    apply Forall_nil.
    
    Unshelve. all: eauto.
  Qed.

  Hint Extern 1 ({{_}} progseq (copydata _ _ _ _) _) => apply copydata_ok : prog.

  Theorem copy2temp_ok : forall fsxp src_inum tinum mscs,
    {< ds Fm Ftop temp_tree src_fn file tfile v0,
    PRE:hm  LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) mscs hm * 
      [[[ ds!! ::: (Fm * DIRTREE.rep fsxp Ftop temp_tree) ]]] *
      [[ DIRTREE.find_subtree [src_fn] temp_tree = Some (DIRTREE.TreeFile src_inum file) ]] *
      [[ DIRTREE.find_subtree [temp_fn] temp_tree = Some (DIRTREE.TreeFile tinum tfile) ]] *
      [[ src_fn <> temp_fn ]] *
      [[[ BFILE.BFData file ::: (0 |-> v0) ]]]
    POST:hm' RET:^(mscs, r)
      exists d tree' f', 
        LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
        [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
        ([[ r = false]] * 
         [[ tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum (BFILE.synced_file f')) temp_tree ]]
        \/ 
         [[ r = true ]] *
         [[ tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum (BFILE.synced_file file)) temp_tree ]])
    XCRASH:hm'
     exists dlist,
        [[ Forall (fun d => (exists tree' tfile', (Fm * DIRTREE.rep fsxp Ftop tree')%pred (list2nmem d) /\
             tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum tfile') temp_tree)) %type dlist ]] *
        ( (* crashed before flushing *)
          LOG.idempred (FSXPLog fsxp) (SB.rep fsxp) (pushdlist dlist ds) hm' \/
          (exists d dlist', [[dlist = d :: dlist' ]] * 
            (* crashed after a flush operation  *)
            (LOG.idempred (FSXPLog fsxp) (SB.rep fsxp) (d, dlist') hm')))
     >} copy2temp fsxp src_inum tinum mscs.
  Proof.
    unfold copy2temp; intros.
    step.
    step.
    step.
    step.
    step.
    AFS.xcrash_solve.
    xcrash_norm.
    or_l.
    instantiate (x := nil). simpl. cancel.
    apply Forall_nil.
    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply. cancel.
    apply Forall_nil.

    step.  (* copydata *)
    rewrite find_subtree_update_subtree_ne. eauto.
    eauto.
    admit. (* xxx push some symbols. *)
    step.
    or_l.
    cancel.
    rewrite update_update_subtree_eq. eauto.
    or_r.
    cancel.
    rewrite update_update_subtree_eq. eauto.

    (* crash condition copydata implies our crash condition.
     * we pushed d on ds before calling copydata 
     * two cases: copydata's crash condition. no sync and sync.
     * but copydata may have synced (d :: ds)  *)
    AFS.xcrash_solve.
    xcrash_norm.  (* case 1: crashed before a sync op *)
    or_l.
    instantiate (x0 := d :: x).  (* the other way around? *)
    admit.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply.
    cancel.
    admit. (* update_update_subtree_eq in forall in H10 *)

    xcrash_norm.  (* case 2: crashed after a sync operation *)
    or_r.
    xcrash_norm.
    admit. (* update_update in H9. *)
    
    step.
    AFS.xcrash_solve.
    xcrash_norm.
    or_l.
    instantiate (x := nil). simpl. cancel.
    apply Forall_nil.
    xcrash_norm.
    or_l.
    instantiate (x0 := [x]).
    cancel.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply.
    cancel.
    apply Forall_nil.

    Unshelve. all:eauto.
  Admitted.

  Hint Extern 1 ({{_}} progseq (copy2temp _ _ _ _) _) => apply copy2temp_ok : prog.

  Theorem copy_rename_ok : forall  fsxp src_inum tinum dst_fn mscs,
    {< ds Fm Ftop temp_tree src_fn file tfile v0,
    PRE:hm  LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) mscs hm * 
      [[[ ds!! ::: (Fm * DIRTREE.rep fsxp Ftop temp_tree) ]]] *
      [[ DIRTREE.find_subtree [src_fn] temp_tree = Some (DIRTREE.TreeFile src_inum file) ]] *
      [[ DIRTREE.find_subtree [temp_fn] temp_tree = Some (DIRTREE.TreeFile tinum tfile) ]] *
      [[[ BFILE.BFData file ::: (0 |-> v0) ]]] *
      [[ src_fn <> temp_fn ]] *
      [[ dst_fn <> temp_fn ]] *
      [[ dst_fn <> src_fn ]]
    POST:hm' RET:^(mscs, r)
      exists d tree' pruned subtree temp_dents dstents,
        LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
        [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
        (([[r = false ]] *
          (exists f',  
          [[ tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum f') temp_tree ]]))) \/
         ([[r = true ]] *
          [[ temp_tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
          [[ pruned = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn temp_tree ]] *
          [[ pruned = DIRTREE.TreeDir the_dnum dstents ]] *
          [[ tree' = DIRTREE.tree_graft the_dnum dstents [] dst_fn subtree pruned ]] *
          [[ subtree = DIRTREE.TreeFile tinum (BFILE.synced_file file) ]])
    XCRASH:hm'
      exists dlist,
        [[ Forall (fun d => (exists tree' tfile', (Fm * DIRTREE.rep fsxp Ftop tree')%pred (list2nmem d) /\
             tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum tfile') temp_tree)) %type dlist ]] *
      (
          (* crashed before flushing *)
          LOG.idempred (FSXPLog fsxp) (SB.rep fsxp) (pushdlist dlist ds) hm' \/
          (exists d dlist', [[dlist = d :: dlist' ]] * 
            (* crashed after a flush operation  *)
            (LOG.idempred (FSXPLog fsxp) (SB.rep fsxp) (d, dlist') hm') \/
            (* crashed after renaming temp file, might have synced (dlist = nil) or not (dlist != nil) *)
            (exists tree' pruned subtree temp_dents dstents,
              [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
              [[ temp_tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
              [[ pruned = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn temp_tree ]] *
              [[ pruned = DIRTREE.TreeDir the_dnum dstents ]] *
              [[ tree' = DIRTREE.tree_graft the_dnum dstents [] dst_fn subtree pruned ]] *
              [[ subtree = DIRTREE.TreeFile tinum (BFILE.synced_file file) ]] *
              LOG.intact (FSXPLog fsxp) (SB.rep fsxp) (d, dlist) hm'))
      )
     >} copy_and_rename fsxp src_inum tinum dst_fn mscs.
  Proof.
    unfold copy_and_rename, AFS.rename_rep; intros.
    step.
    step.
    instantiate (cwd0 := []).
    admit.  (* boring *)
    step.
    step.
    AFS.xcrash_solve.
    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists.
    eexists.
    intuition.
    pred_apply. cancel.
    apply Forall_nil.

    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists. eexists. intuition.
    pred_apply; cancel.
    admit. (* what do i know about x0? *)
    apply Forall_nil.
  
    unfold AFS.rename_rep.
    cancel.
    admit. (* something slightly wrong *)

    step.
    instantiate (F_1 := F_).
    cancel.
    or_r.
    cancel.
    admit.
    admit.
    admit.
    
    AFS.xcrash_solve.
    xcrash_norm.
    or_l.
    instantiate (x := nil); simpl; cancel.
    apply Forall_nil.

    xcrash_norm.
    or_r.
    xcrash_norm.
    admit.  (* same problem with x0 *)
    
    AFS.xcrash_solve.
    xcrash_norm.
    or_r.
    xcrash_norm.
    apply Forall_cons.
    eexists. eexists. intuition.
    pred_apply. cancel.
    apply Forall_nil.

    AFS.xcrash_solve.
    xcrash_norm.
    xcrash_norm.
    or_r.
    xcrash_norm.
    eauto.
    Unshelve. all: eauto.
  Admitted.

  Hint Extern 1 ({{_}} progseq (copy_and_rename _ _ _ _ _) _) => apply copy_rename_ok : prog.

  (* specs for copy_and_rename_cleanup and atomic_cp *)

  Theorem atomic_cp_recover_ok :
    {< fsxp cs ds,
    PRE:hm
      LOG.after_crash (FSXPLog fsxp) (SB.rep fsxp) ds cs hm (* every ds must have a tree *)
    POST:hm' RET:^(ms, fsxp')
      [[ fsxp' = fsxp ]] * exists d n tree tree' Fm' Fm'' Ftop' Ftop'' temp_dents, 
       [[ n <= List.length (snd ds) ]] *
       LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) ms hm' *
       [[[ d ::: Fm'' * DIRTREE.rep fsxp Ftop'' tree' ]]] *
       [[[ nthd n ds ::: (Fm' * DIRTREE.rep fsxp Ftop' tree) ]]] *
       [[ tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
       [[ tree' = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn tree ]]
    CRASH:hm'
      LOG.after_crash (FSXPLog fsxp) (SB.rep fsxp) ds cs hm'
     >} recover.
  Proof.
    unfold recover; intros.
    step.
  Admitted.

  Hint Extern 1 ({{_}} progseq (recover) _) => apply atomic_cp_recover_ok : prog.

  Theorem atomic_cp_with_recover_ok : forall fsxp src_inum dst_fn mscs,
    {<< ds Fm Ftop temp_tree src_fn file tinum tfile,
    PRE:hm LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn ds) mscs hm * 
      [[[ ds!! ::: (Fm * DIRTREE.rep fsxp Ftop temp_tree) ]]] *
      [[ DIRTREE.find_subtree [src_fn] temp_tree = Some (DIRTREE.TreeFile src_inum file) ]] *
      [[ DIRTREE.find_subtree [temp_fn] temp_tree = Some (DIRTREE.TreeFile tinum tfile) ]] *
      [[[ BFILE.BFData file ::: (0 |-> v0) ]]] *
      [[ src_fn <> temp_fn ]] *
      [[ dst_fn <> temp_fn ]] *
      [[ dst_fn <> src_fn ]]
    POST:hm' RET:^(mscs, r)
      exists d tree' pruned subtree temp_dents dstents,
        LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
        [[[ d ::: (Fm * DIRTREE.rep fsxp Ftop tree') ]]] *
        (([[r = false ]] *
          (exists f',  
          [[ tree' = DIRTREE.update_subtree [temp_fn] (DIRTREE.TreeFile tinum f') temp_tree ]]))) \/
         ([[r = true ]] *
          [[ temp_tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
          [[ pruned = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn temp_tree ]] *
          [[ pruned = DIRTREE.TreeDir the_dnum dstents ]] *
          [[ tree' = DIRTREE.tree_graft the_dnum dstents [] dst_fn subtree pruned ]] *
          [[ subtree = DIRTREE.TreeFile tinum (BFILE.synced_file file) ]])
    REC:hm' RET:^(mscs,fsxp')
     [[ fsxp' = fsxp ]] * exists d n tree tree' Fm' Fm'' Ftop' Ftop'' temp_dents pruned, 
       [[ n <= List.length (snd ds) ]] *
       LOG.rep (FSXPLog fsxp) (SB.rep fsxp) (LOG.NoTxn (d, nil)) mscs hm' *
       [[[ d ::: Fm'' * DIRTREE.rep fsxp Ftop'' tree' ]]] *
       [[[ nthd n ds ::: (Fm' * DIRTREE.rep fsxp Ftop' tree) ]]] *
       [[ tree = DIRTREE.TreeDir the_dnum temp_dents ]] *
       [[ pruned = DIRTREE.tree_prune the_dnum temp_dents [] temp_fn tree ]] *
       ([[ tree' = pruned ]] \/
        exists subtree dstents,
        [[ tree' = DIRTREE.tree_graft the_dnum dstents [] dst_fn subtree pruned ]] *
        [[ pruned = DIRTREE.TreeDir the_dnum dstents ]] *
        [[ subtree = DIRTREE.TreeFile tinum (BFILE.synced_file file) ]])
    >>} copy_and_rename fsxp src_inum tinum dst_fn mscs >> recover.
  Proof.
    AFS.recover_ro_ok.
    cancel.
    eauto.
    eauto.
    congruence.
    congruence.
    step.
   Admitted.

End ATOMICCP.

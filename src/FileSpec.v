Require Import Arith.
Require Import CpdtTactics.
Require Import FsTactics.
Require Import Storage.

Definition inodenum := nat.
Definition blockoffset := nat.

Inductive fileop : Type -> Type :=
  | FRead (i:inodenum) (o:blockoffset): fileop block
  | FWrite (i:inodenum) (o:blockoffset) (b:block): fileop unit
  | FAlloc: fileop (option inodenum)
  | FFree (i:inodenum): fileop unit
  | FTrunc (i:inodenum) (len:blockoffset): fileop unit.

Inductive fprog :=
  | FCommon {R:Type} (o:fileop R) (rx:R->fprog)
  | FHalt.

Record file := File {
  FIsFree: bool;
  FLen: blockoffset;
  FData: { o: blockoffset | o < FLen } -> block
}.

Definition fstatedata := inodenum -> file.

Record fstate := FSt {
  FSProg: fprog;
  FSData: fstatedata
}.

Definition setidx {K: Type} {V: Type}
                  (eq: forall (a b:K), {a=b}+{a<>b})
                  (db: K->V) (k: K) (v: V) :=
  fun x: K => if eq x k then v else db x.

Definition setidxsig {K: Type} {V: Type} {KP: K->Prop}
                     (eq: forall (a b:K), {a=b}+{a<>b})
                     (db: (sig KP) -> V) (k: K) (v: V) :=
  fun x: (sig KP) => if eq (proj1_sig x) k then v else db x.

Ltac crush_inv_sig := intros; inv_sig; crush.

Program Definition nodata: { o: blockoffset | o < 0 } -> block.
  crush_inv_sig.
Qed.

Program Definition shrinkdata {oldlen: blockoffset}
                              {len: blockoffset}
                              (SHRINK: len <= oldlen)
                              (olddata: {o : blockoffset | o < oldlen} -> block) :=
  fun x: {o: blockoffset | o < len} => olddata (exist _ (proj1_sig x) _).
Next Obligation.
  crush.
Qed.

Program Definition growzerodata {oldlen: blockoffset}
                                {len: blockoffset}
                                (GROW: len > oldlen)
                                (olddata: {o: blockoffset | o < oldlen} -> block) :=
  fun x: {o: blockoffset | o < len} =>
    if lt_dec (proj1_sig x) oldlen then olddata x else 0.

Inductive fstep: fstate -> fstate -> Prop :=
  | FsmRead: forall inum off rx d bdata f
    (F: f = d inum)
    (NOTFREE: FIsFree f = false)
    (OLEN: off < FLen f)
    (BD: bdata = FData f (exist _ off OLEN)),
    fstep (FSt (FCommon (FRead inum off) rx) d)
          (FSt (rx bdata) d)
  | FsmWrite: forall inum off rx bdata d d' f f'
    (F: f = d inum)
    (NOTFREE: FIsFree f = false)
    (OLEN: off < FLen (d inum))
    (F': f' = File (FIsFree f) (FLen f) (setidxsig eq_nat_dec (FData f) off bdata))
    (D': d' = setidx eq_nat_dec d inum f'),
    fstep (FSt (FCommon (FWrite inum off bdata) rx) d)
          (FSt (rx tt) d')
  | FsmAllocOK: forall rx inum f f' d d'
    (F: f = d inum)
    (FREE: FIsFree f = true)
    (F': f' = File false 0 nodata)
    (D': d' = setidx eq_nat_dec d inum f'),
    fstep (FSt (FCommon FAlloc rx) d)
          (FSt (rx (Some inum)) d')
  | FsmAllocNone: forall rx d
    (ALLUSED: forall inum, FIsFree (d inum) = false),
    fstep (FSt (FCommon FAlloc rx) d)
          (FSt (rx None) d)
  | FsmFree: forall inum rx d d' f f' len fdata
    (F: f = d inum)
    (NOTFREE: FIsFree f = false)
    (F': f' = File true len fdata)
    (D': d' = setidx eq_nat_dec d inum f'),
    fstep (FSt (FCommon (FFree inum) rx) d)
          (FSt (rx tt) d')
  | FsmTruncShrink: forall inum len rx d d' f f'
    (F: f = d inum)
    (NOTFREE: FIsFree f = false)
    (SHRINK: len <= FLen f)
    (F': f' = File false len (shrinkdata SHRINK (FData f)))
    (D': d' = setidx eq_nat_dec d inum f'),
    fstep (FSt (FCommon (FTrunc inum len) rx) d)
          (FSt (rx tt) d')
  | FsmTruncGrow: forall inum len rx d d' f f'
    (F: f = d inum)
    (NOTFREE: FIsFree f = false)
    (GROW: len > FLen f)
    (F': f' = File false len (growzerodata GROW (FData f)))
    (D': d' = setidx eq_nat_dec d inum f'),
    fstep (FSt (FCommon (FTrunc inum len) rx) d)
          (FSt (rx tt) d')
  | FsmHalt: forall d,
    fstep (FSt FHalt d)
          (FSt FHalt d).

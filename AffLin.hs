module AffLin where
import qualified Data.Map as Map
import Data.List
import Exprs
import Ctxt
import Util
import Name


{- ====== Affine to Linear Functions ====== -}
-- These functions convert affine terms to
-- linear ones, where an affine term is one where
-- every bound var occurs at most once, and a
-- linear term is one where every bound var
-- occurs exactly once
type FreeVars = Map.Map Var Type

-- Uses x without changing the value or type of a term
-- For example, take x : Bool and some term tm that becomes
-- case x of false -> tm | true -> tm
discard :: Ctxt -> Var -> Type -> Term -> Term
discard g x (TpArr tp1 tp2) tm =
  error "This shouldn't happen" -- Should be TpMaybe if it is an arrow type
discard g x (TpVar y) tm = maybe2 (ctxtLookupType g y)
  (error ("In Free.hs/discard, unknown type var " ++ y))
  $ \ cs ->
      TmCase (TmVarL x (TpVar y)) (TpVar y)
        (map (\ (Ctor x' as) ->
                let as' = getArgs x' as in
                  Case x' as' (foldr (uncurry $ discard g) tm as'))
          cs) (getType tm)
discard g x (TpMaybe tp) tm =
  let x' = aff2linName x
      tp' = getType tm in
    tmElimMaybe (TmVarL x (TpMaybe tp)) tp tm
      (x', TmApp (TmApp (TmSamp DistFail (TpArr tp (TpArr tp' tp')))
                   (TmVarL x' tp) tp (TpArr tp' tp')) tm tp' tp') tp'
discard g x TpBool tm =
  tmIf (TmVarL x TpBool) tm tm (getType tm)

-- Discard a set of variables
discards :: Ctxt -> FreeVars -> Term -> Term
discards g fvs tm = Map.foldrWithKey (discard g) tm fvs

-- Convert the type of an affine term to what it will be when linear
-- That is, recursively change every T1 -> T2 to be Maybe (T1 -> T2)
aff2linTp :: Type -> Type
aff2linTp (TpVar y) = TpVar y
aff2linTp (TpArr tp1 tp2) = TpMaybe (TpArr (aff2linTp tp1) (aff2linTp tp2))
aff2linTp tp = error ("aff2linTp shouldn't see a " ++ show tp)

-- Make a case linear, returning the local vars that occur free in it
aff2linCase :: Ctxt -> Case -> (Case, FreeVars)
aff2linCase g (Case x as tm) =
  let (tm', fvs) = aff2linh (ctxtDeclArgs g as) tm
      -- Need to discard all "as" that do not occur free in "tm"
      tm'' = discards g (Map.difference (Map.fromList as) fvs) tm' in
    (Case x as tm'', foldr (Map.delete . fst) fvs as)

-- Make a term linear, returning the local vars that occur free in it
aff2linh :: Ctxt -> Term -> (Term, FreeVars)
aff2linh g (TmVarL x tp) =
  let ltp = aff2linTp tp in
    (TmVarL x ltp, Map.singleton x ltp)
aff2linh g (TmVarG gv x as y) =
  let (as', fvss) = unzip $ flip map as $
        \ (tm, tp) -> let (tm', xs) = aff2linh g tm in ((tm', aff2linTp tp), xs) in
  (TmVarG gv x as' y, Map.unions fvss)
aff2linh g (TmLam x tp tm tp') =
  let ltp = aff2linTp tp
      ltp' = aff2linTp tp'
      (tm', fvs) = aff2linh (ctxtDeclTerm g x ltp) tm
      fvs' = Map.delete x fvs
      tm'' = if Map.member x fvs then tm' else discard g x ltp tm'
      jtm = TmVarG CtorVar tmJustName
              [(TmLam x ltp tm'' ltp', TpArr ltp ltp')] (TpMaybe (TpArr ltp ltp'))
      ntm = discards g fvs'
              (TmVarG CtorVar tmNothingName [] (TpMaybe (TpArr ltp ltp'))) in
    (tmIf (TmSamp DistAmb TpBool) jtm ntm (TpMaybe (TpArr ltp ltp')), fvs')
aff2linh g (TmApp tm1 tm2 tp2 tp) =
  let (tm1', fvs1) = aff2linh g tm1
      (tm2', fvs2) = aff2linh g tm2
      ltp2 = aff2linTp tp2
      ltp = aff2linTp tp
      fvs = Map.union fvs1 fvs2
      ntm = TmApp (TmSamp DistFail (TpArr ltp2 ltp)) tm2' ltp2 ltp
      jx = etaName tmJustName 0
      jtm = TmApp (TmVarL jx (TpArr ltp2 ltp)) tm2' ltp2 ltp in
    (tmElimMaybe tm1' (TpArr ltp2 ltp) ntm (jx, jtm) ltp, fvs)
aff2linh g (TmLet x xtm xtp tm tp) =
  let xtp' = aff2linTp xtp
      tp' = aff2linTp tp
      (xtm', fvsx) = aff2linh g xtm
      (tm', fvs) = aff2linh (ctxtDeclTerm g x xtp') tm
      tm'' = if Map.member x fvs then tm' else discard g x xtp' tm'
  in
    (TmLet x xtm' xtp' tm'' tp', Map.union fvsx (Map.delete x fvs))
aff2linh g (TmCase tm y cs tp) =
  let csxs = map (aff2linCase g) cs
      xsAny = Map.unions (map snd csxs)
      (tm', tmxs) = aff2linh g tm
      cs' = flip map csxs $ \ (Case x as tm', xs) -> Case x as $
                  -- Need to discard any vars that occur free in other cases, but
                  -- not in this one bc all cases must have same set of free vars
                  discards (ctxtDeclArgs g as) (Map.difference xsAny xs) tm' in
    (TmCase tm' y cs' (aff2linTp tp), Map.union xsAny tmxs)
aff2linh g (TmSamp d tp) = (TmSamp d (aff2linTp tp), Map.empty)
aff2linh g (TmFold fuf tm tp) =
  let (tm', fvs) = aff2linh g tm in
    (TmFold fuf tm' (aff2linTp tp), fvs)

-- Makes an affine term linear
aff2linTerm :: Ctxt -> Term -> Term
aff2linTerm g tm = fst (aff2linh g tm)
{-  let (tm', fvs) = aff2linh g tm in
    if Map.null fvs
      then tm'
      else error ("in aff2lin, remaining free vars: " ++ show (Map.keys fvs))-}

-- Make an affine Prog linear
aff2linProg :: Ctxt -> Prog -> Prog
aff2linProg g (ProgFun x (_ : _) tm tp) = error "ProgFun should not have params before aff2lin"
aff2linProg g (ProgExtern x xp (_ : _) tp) = error "ProgExtern should not have params before aff2lin"
aff2linProg g (ProgFun x [] tm tp) =
  let (as, endtp) = splitArrows tp
      (ls, endtm) = splitLams tm
      as' = map aff2linTp as
      ls' = map (fmap aff2linTp) ls
      etas = map (\ (i, atp) -> (etaName x i, atp)) (drop (length ls') (enumerate as'))
      g' = ctxtDeclArgs g ls'
      endtm' = aff2linTerm g' endtm
      endtp' = aff2linTp endtp -- This may not be necessary, but is future-proof
  in
    ProgFun x (ls' ++ etas) (joinApps endtm' (toTermArgs etas)) endtp'
aff2linProg g (ProgExtern x xp [] tp) =
  let (as, end) = splitArrows tp
      as' = map aff2linTp as in
    ProgExtern x xp as' end
aff2linProg g (ProgData y cs) =
  ProgData y (map (\ (Ctor x as) -> Ctor x (map aff2linTp as)) cs)

-- Make an affine file linear
aff2linFile :: Progs -> Either String Progs
aff2linFile (Progs ps end) =
  let g = ctxtDefProgs (Progs ps end) in
    return (Progs (map (aff2linProg g) ps) (aff2linTerm g end))

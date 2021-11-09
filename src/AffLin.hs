module AffLin where
import qualified Data.Map as Map
import Control.Monad.RWS
import Exprs
import Ctxt
import Util
import Name
import Free

{- ====== Affine to Linear Functions ====== -}
-- These functions convert affine terms to
-- linear ones, where an affine term is one where
-- every bound var occurs at most once, and a
-- linear term is one where every bound var
-- occurs exactly once

-- Reader, Writer, State monad
type AffLinM a = RWS Ctxt FreeVars [Type] a
-- Let m = monad type, r = reader type, w = writer type, and s = state type. Then
--
-- ask :: m r
-- local :: (r -> r) -> m a -> m a
--
-- tell :: w -> m ()
-- censor :: (w -> w) -> m a -> m a
-- listen :: m a -> m (a, w)
--
-- get :: m s
-- put :: s -> m ()
-- modify :: (s -> s) -> m ()

-- Looks up the maybe type for an arrow type
getToMaybe :: Type -> AffLinM (Maybe Int)
getToMaybe tp =
  get >>= \ mtps ->
  return (lookup tp (zip mtps [0..]))

-- Looks up the original arrow type, given some maybe type
getFromMaybe :: Var -> AffLinM (Maybe (Int, Type))
getFromMaybe y =
  get >>= \ mtps ->
  return (lookup y [(tpMaybeName i, (i, tp)) | (i, tp) <- enumerate mtps])

-- Adds a new maybe type to the state
addMaybe :: Type -> AffLinM Int
addMaybe tp =
  get >>= \ mtps ->
  put (mtps ++ [tp]) >>
  return (length mtps)

-- If tp already has a Maybe, return its index.
-- Otherwise add a new Maybe and return its index.
getMaybe :: Type -> AffLinM Int
getMaybe tp =
  getToMaybe tp >>= maybe (addMaybe tp) return

-- Bind x : tp inside an AffLinM
alBind :: Var -> Type -> AffLinM Term -> AffLinM Term
alBind x tp m =
  censor (Map.delete x)
         (listen (local (\ g -> ctxtDeclTerm g x tp) m) >>= \ (tm, fvs) ->
            if Map.member x fvs then return tm else discard x tp tm)

-- Bind a list of params inside an AffLinM
alBinds :: [Param] -> AffLinM Term -> AffLinM Term
alBinds ps m = foldl (\ m (x, tp) -> alBind x tp m) m ps


-- Computes if a type has an arrow / Maybe type somewhere in it
needToDiscard :: Type -> AffLinM Bool
needToDiscard (TpVar y) =
  getFromMaybe y >>= maybe
    (ask >>= \ g -> maybe
      (return False)
      (\ cs -> mapM (\ (Ctor x tps) -> mapM needToDiscard tps >>= return . or) cs >>= return . or)
      (ctxtLookupType g y))
    (\ (i, tp') -> return True)
needToDiscard (TpArr tp1 tp2) = error "Hmm... This shouldn't happen"
needToDiscard (TpAmp tps) = return True
needToDiscard (TpProd tps) = mapM needToDiscard tps >>= return . or

-- Maps something to Unit
-- For example, take x : Bool, which becomes
-- case x of false -> unit | true -> unit
discard' :: Term -> Type -> AffLinM Term
discard' x (TpArr tp1 tp2) =
  error ("Can't discard " ++ show x ++ " : " ++ show (TpArr tp1 tp2))
discard' x (TpAmp tps) = discard' (TmAmpOut x tps (length tps - 1)) (last tps)
discard' x (TpProd tps) = let ps = [(etaName "_" i, tp) | (i, tp) <- enumerate tps] in discards (Map.fromList ps) tmUnit >>= \ tm -> return (TmProdOut x ps tm tpUnit)
discard' x (TpVar y) =
  ask >>= \ g ->
  getFromMaybe y >>=
  maybe
    (maybe2 (ctxtLookupType g y)
      (error ("In Free.hs/discard, unknown type var " ++ y))
      (mapM (\ (Ctor x' as) ->
               let as' = nameParams x' as in
                 alBinds as' (return tmUnit) >>= \ tm ->
                 return (Case x' as' tm))))
    (\ (i, tp') -> return
      [Case (tmNothingName i) [] tmUnit,
       Case (tmJustName i) [("_", tp')] (TmSamp DistFail tpUnit)]) >>= \ cs' ->
  return (TmCase x y cs' tpUnit)

-- If x : tp contains an affinely-used function, we sometimes need to discard
-- it to maintain correct probabilities, but without changing the value or type
-- of some term. This maps x to Unit, then case-splits on it.
-- So to discard x : MaybeA2B in tm, this returns
-- case (case x of nothing -> unit | just a2b -> fail) of unit -> tm
discard :: Var -> Type -> Term -> AffLinM Term
discard x tp tm =
  needToDiscard tp >>= \ has_arr ->
  if has_arr
    then (discard' (TmVarL x tp) tp >>= \ dtm -> return (TmLet "_" dtm tpUnit tm (getType tm))) -- (tmElimUnit dtm tm (getType tm)))
    else return tm

-- Discard a set of variables
discards :: FreeVars -> Term -> AffLinM Term
discards fvs tm = Map.foldlWithKey (\ tm x tp -> tm >>= discard x tp) (return tm) fvs

-- Convert the type of an affine term to what it will be when linear
-- That is, recursively change every T1 -> T2 to be Maybe (T1 -> T2)
affLinTp :: Type -> AffLinM Type
affLinTp (TpVar y) = return (TpVar y)
affLinTp (TpAmp tps) = pure TpAmp <*> mapM affLinTp (tps ++ [tpUnit])
affLinTp (TpProd tps) = pure TpProd <*> mapM affLinTp tps
affLinTp (TpArr tp1 tp2) =
  let (tps, end) = splitArrows (TpArr tp1 tp2) in
    mapM affLinTp tps >>= \ tps' ->
    getMaybe (joinArrows tps' end) >>= \ i ->
    return (tpMaybe i)

-- Make a case linear, returning the local vars that occur free in it
affLinCase :: Case -> AffLinM Case
affLinCase (Case x ps tm) =
  mapParamsM affLinTp ps >>= \ ps' ->
  alBinds ps' (affLin tm) >>=
  return . Case x ps'

ambFun :: Term -> FreeVars -> AffLinM Term
ambFun tm fvs =
  let tp = getType tm in
    case tp of
      TpArr _ _ ->
        getMaybe tp >>= \ i ->
        discards fvs (tmNothing i) >>= \ ntm ->
        return (TmAmb [ntm, tmJust i tm tp] (tpMaybe i))
      _ -> return tm

ambElim :: Term -> (Term -> AffLinM Term) -> AffLinM Term
ambElim tm app =
  case getType tm of
     TpVar y ->
       getFromMaybe y >>= maybe (app tm)
         (\ (i, tp) ->
             let x = affLinName (tmJustName i) in
               app (TmVarL x tp) >>= \ jtm ->
               let tp' = getType jtm
                   nc = Case (tmNothingName i) [] (TmSamp DistFail tp')
                   jc = Case (tmJustName i) [(x, tp)] jtm in
                 return (TmCase tm y [nc, jc] tp'))
     _ -> app tm

affLinParams :: [Param] -> Term -> AffLinM ([Param], Term, FreeVars)
affLinParams ps body =
  mapParamsM affLinTp ps >>= \ lps ->
  listen (alBinds lps (affLin body)) >>= \ (body', fvs) ->
  ambElim body' return >>= \ body'' ->
  return (lps, body'', fvs)
      
affLinLams :: Term -> AffLinM ([Param], Term, FreeVars)
affLinLams = uncurry affLinParams . splitLams

affLinBranches :: (a -> AffLinM b) -> (FreeVars -> b -> AffLinM b) -> [a] -> AffLinM [b]
affLinBranches alf dscrd als =
  listen (mapM (listen . alf) als) >>= \ (alxs, xsAny) ->
  mapM (\ (b, xs) -> dscrd (Map.difference xsAny xs) b) alxs

-- Make a term linear, returning the local vars that occur free in it
affLin :: Term -> AffLinM Term
affLin (TmVarL x tp) =
  affLinTp tp >>= \ ltp ->
  tell (Map.singleton x ltp) >>
  return (TmVarL x ltp)
affLin (TmVarG gv x as y) =
  mapArgsM affLin as >>= \ as' ->
  affLinTp y >>= \ y' ->
  return (TmVarG gv x as' y')
affLin (TmLam x tp tm tp') =
  affLinLams (TmLam x tp tm tp') >>= \ (lps, body, fvs) ->
  ambFun (joinLams lps body) fvs
affLin (TmApp tm1 tm2 tp2 tp) =
  let (tm, as) = splitApps (TmApp tm1 tm2 tp2 tp) in
    listen (pure (,) <*> affLin tm <*> mapArgsM affLin as) >>= \ ((tm', as'), fvs) ->
    ambElim tm' (\ tm -> ambFun (joinApps tm as') fvs)
affLin (TmLet x xtm xtp tm tp) =
  affLin xtm >>= \ xtm' ->
  let xtp' = getType xtm' in
    alBind x xtp' (affLin tm) >>= \ tm' ->
    return (TmLet x xtm' xtp' tm' (getType tm'))
affLin (TmCase tm y cs tp) =
  affLin tm >>= \ tm' ->
--  listen (mapM (listen . affLinCase) cs) >>= \ (csxs, xsAny) ->
--  mapM (\ (Case x as tm, xs) -> fmap (Case x as)
--             (discards (Map.difference xsAny xs) tm)) csxs >>= \ cs' ->
  affLinBranches affLinCase (\ xs (Case x as tm) -> fmap (Case x as) (discards xs tm)) cs >>= \ cs' ->
  case cs' of
    [] -> affLinTp tp >>= return . TmCase tm' y cs'
    (Case _ _ xtm) : rest -> return (TmCase tm' y cs' (getType xtm))
affLin (TmSamp d tp) =
  affLinTp tp >>= \ tp' ->
  return (TmSamp d tp')
affLin (TmAmb tms tp) =
--  listen (mapM (listen . affLin) tms) >>= \ (tmsxs, xsAny) ->
--  mapM (\ (tm, xs) -> discards (Map.difference xsAny xs) tm) tmsxs >>= \ tms' ->
  affLinBranches affLin discards tms >>= \ tms' ->
  (if null tms' then affLinTp tp else return (getType (head tms'))) >>= \ tp' ->
  return (TmAmb tms' tp')
affLin (TmAmpIn as) =
  pure TmAmpIn <*> affLinBranches (mapArgM affLin) (mapArgM . discards) (as ++ [(tmUnit, tpUnit)])
affLin (TmAmpOut tm tps o) =
  pure TmAmpOut <*> affLin tm <*> mapM affLinTp (tps ++ [tpUnit]) <*> pure o
affLin (TmProdIn as) = pure TmProdIn <*> mapArgsM affLin as
affLin (TmProdOut tm ps tm' tp) =
  affLin tm >>= \ tm ->
  affLinParams ps tm' >>= \ (ps, tm', fvs) ->
  discards (Map.intersection (Map.fromList ps) fvs) tm' >>= \ tm' ->
  return (TmProdOut tm ps tm' (getType tm'))

-- Make an affine Prog linear
affLinProg :: Prog -> AffLinM Prog
affLinProg (ProgFun x _ tm tp) =
  let (as, endtp) = splitArrows tp
      (ls, endtm) = splitLams tm
      etas = [ (etaName x i, atp) | (i, atp) <- drop (length ls) (enumerate as) ]
      endtm_eta = joinApps endtm (paramsToArgs etas)
      ls_eta = ls ++ etas
  in
    mapM affLinTp as >>= \ as' ->
    mapParamsM affLinTp ls_eta >>= \ ls_eta' ->
    alBinds ls_eta' (affLin endtm_eta) >>= \ endtm' ->
    return (ProgFun x ls_eta' endtm' (getType endtm'))
affLinProg (ProgExtern x xp _ tp) =
  let (as, end) = splitArrows tp in
    mapM affLinTp as >>= \ as' ->
    return (ProgExtern x xp as' end)
affLinProg (ProgData y cs) =
  pure (ProgData y) <*> mapCtorsM affLinTp cs

-- Helper
affLinDefine :: Prog -> AffLinM Prog
affLinDefine (ProgData y cs) =
  pure (ProgData y) <*> mapCtorsM affLinTp  cs
affLinDefine (ProgFun x [] tm tp) =
  let (as, endtp) = splitArrows tp in
    mapM affLinTp as >>= \ as' ->
    return (ProgFun x [] tm (joinArrows as' endtp))
affLinDefine (ProgFun _ (_ : _) _ _) =
  error "Function shouldn't have params before affine-to-linear transformation"
affLinDefine (ProgExtern _ _ (_ : _) _) =
  error "Extern shouldn't have params before affine-to-linear transformation"
affLinDefine (ProgExtern x xp [] tp) =
  let (as, endtp) = splitArrows tp in
    mapM affLinTp as >>= \ as' ->
    return (ProgExtern x xp [] (joinArrows as' tp))

-- Adds all the definitions in a file to context, after replacing arrows with Maybes
affLinDefines :: Progs -> AffLinM Ctxt
affLinDefines (Progs ps end) =
  mapM affLinDefine ps >>= \ ps' ->
  return (ctxtDefProgs (Progs ps' end))

affLinProgs :: Progs -> AffLinM Progs
affLinProgs (Progs ps end) =
  affLinDefines (Progs ps end) >>= \ g ->
  local (const g) (pure Progs <*> mapM affLinProg ps <*> affLin end)

runAffLin :: Progs -> Progs
runAffLin ps = case runRWS (affLinProgs ps) (ctxtDefProgs ps) [] of
  (Progs ps' end, mtps, _) -> Progs (ps' ++ [ProgData (tpMaybeName i) (maybeCtors i tp) | (i, tp) <- enumerate mtps]) end

-- Make an affine file linear
affLinFile :: Progs -> Either String Progs
affLinFile = return . runAffLin

module FGG where
import qualified Data.Map as Map
import Data.List
import Util
import Exprs
import Tensor
import Show()

-- Should the compiler make sure there aren't conflicting nonterminal domains?
checkDomsEq = True

{- ====== JSON Functions ====== -}

data JSON =
    JSnull
  | JSbool Bool
  | JSint Int
  | JSdouble Double
  | JSstring String
  | JSarray [JSON]
  | JSobject [(String, JSON)]

instance Show JSON where
  show JSnull = "null"
  show (JSbool b) = if b then "true" else "false"
  show (JSint i) = show i
  show (JSdouble d) = show d
  show (JSstring s) = show s
  show (JSarray js) = '[' : delimitWith "," [show a | a <- js] ++ "]"
  show (JSobject kvs) = '{' : delimitWith "," [show k ++ ":" ++ show v | (k, v) <- kvs] ++ "}"


{- ====== FGG Functions ====== -}

type Nonterminal = (Var, Type)
type Domain = [String]
type Value = String
type FType = [Value]
type Factor = (String, Weights)
type Prob = Double
type Weights = Tensor Prob
data Edge = Edge { edge_atts :: [Int], edge_label :: String }
  deriving Eq
data Edge' = Edge' { edge_atts' :: [(Var, Type)], edge_label' :: String }
  deriving Eq
data HGF = HGF { hgf_nodes :: [Type], hgf_edges :: [Edge], hgf_exts :: [Int]}
  deriving Eq
data HGF' = HGF' { hgf_nodes' :: [(Var, Type)], hgf_edges' :: [Edge'], hgf_exts' :: [(Var, Type)] }
  deriving Eq
data Rule = Rule String HGF
  deriving Eq
data FGG_JSON = FGG_JSON {
  domains :: Map.Map String FType,
  factors :: Map.Map String (Domain, Weights),
  nonterminals :: Map.Map String Domain,
  start :: String,
  rules :: [Rule]
}

concatFactors :: [Factor] -> [Factor] -> [Factor]
concatFactors [] gs = gs
concatFactors ((x, w) : fs) gs =
  let hs = concatFactors fs gs in
    maybe ((x, w) : hs) (\ _ -> hs) (lookup x gs)

weights_to_json :: Weights -> JSON
weights_to_json (Scalar n) = JSdouble n
weights_to_json (Vector ts) = JSarray [weights_to_json v | v <- ts]

-- Print a comma-separated list
join_list :: Show a => [a] -> String
join_list [] = ""
join_list (a : []) = show a
join_list (a : as) = show a ++ "," ++ join_list as

-- Print a comma-separated key-value dict
join_dict :: Show a => [(String, a)] -> String
join_dict [] = ""
join_dict ((k, v) : []) = show k ++ ":" ++ show v
join_dict ((k, v) : kvs) = show k ++ ":" ++ show v ++ "," ++ join_dict kvs

-- Convert an FGG into a JSON
fgg_to_json :: FGG_JSON -> JSON
fgg_to_json (FGG_JSON ds fs nts s rs) =
  let mapToList = \ ds f -> JSobject $ Map.toList $ fmap f ds in
  JSobject
    [("domains", mapToList ds $
       \ ds' -> JSobject [
         ("class", JSstring "finite"),
         ("values", JSarray $ map JSstring ds')
       ]),
      
     ("factors", mapToList fs $
       \ (d, ws) -> JSobject [
         ("function", JSstring "categorical"),
         ("type", JSarray $ map JSstring d),
         ("weights", weights_to_json ws)
       ]),
      
     ("nonterminals", mapToList nts $
       \ d -> JSobject [
         ("type", JSarray $ map JSstring d)
       ]),

     ("start", JSstring s),

     ("rules", JSarray $ flip map (nub rs) $
       \ (Rule lhs (HGF ns es xs)) -> JSobject [
           ("lhs", JSstring lhs),
           ("rhs", JSobject [
               ("nodes", JSarray [JSobject [("label", JSstring (show n))] | n <- ns]),
               ("edges", JSarray $ flip map es $
                 \ (Edge atts l) -> JSobject [
                   ("attachments", JSarray (map JSint atts)),
                   ("label", JSstring l)
                 ]),
               ("externals", JSarray $ map JSint xs)
             ])
       ])
    ]

instance Show FGG_JSON where
  show = show . fgg_to_json


-- Default FGG
emptyFGG :: String -> FGG_JSON
emptyFGG s = FGG_JSON Map.empty Map.empty Map.empty s []

-- Construct an FGG from a list of rules, a start symbol,
-- and a function that gives the possible values of each type
rulesToFGG :: (Type -> [String]) -> String -> [Rule] -> [Nonterminal] -> [Factor] -> FGG_JSON
rulesToFGG doms start rs nts facs =
  let rs' = nub rs
      ds  = foldr (\ (Rule lhs (HGF ns es xs)) m ->
                     foldr (\ n -> Map.insert (show n) (doms n)) m ns) Map.empty rs'
      domsEq = \ x d1 d2 -> if not checkDomsEq || d1 == d2 then d1 else error
        ("Conflicting domains for nonterminal " ++ x ++ ": " ++
          show d1 ++ " vs " ++ show d2)
      nts'' = foldr (\ (x, tp) -> Map.insert x [show tp]) Map.empty nts
      nts' = foldr (\ (Rule lhs (HGF ns _ xs)) ->
                      Map.insertWith (domsEq lhs) lhs [show (ns !! i) | i <- xs]) nts'' rs'
      getFac = \ l lhs -> maybe (error ("In the rule " ++ lhs ++ ", no factor named " ++ l))
                        id $ lookup l facs
      fs  = foldr (\ (Rule lhs (HGF ns es xs)) m ->
                     foldr (\ (Edge atts l) ->
                               if Map.member l nts' then id else
                                 Map.insert l ([show (ns !! i) | i <- atts], getFac l lhs))
                           m es)
                  Map.empty rs'
  in
    FGG_JSON ds fs nts' start rs'
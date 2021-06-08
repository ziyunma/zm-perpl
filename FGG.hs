module FGG where
import qualified Data.Map as Map
import Data.List
import Exprs
import Ctxt

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
  show (JSarray js) = '[' : (join_list js ++ "]")
  show (JSobject kvs) = '{' : (join_dict kvs ++ "}")


type Domain = [String]
type Value = String
type FType = [Value]
type Prob = Double
data WeightsH x = WeightsData x | WeightsDims (WeightsH [x])
type Weights = WeightsH Prob
data Edge = Edge { edge_atts :: [Int], edge_label :: String }
  deriving Eq
data HGF = HGF { hgf_nodes :: [String], hfg_edges :: [Edge], hfg_exts :: [Int]}
  deriving Eq
data Rule = Rule String HGF
  deriving Eq
data FGG_JSON = FGG_JSON {
  domains :: Map.Map String FType,
  factors :: Map.Map String (Domain, Weights),
  nonterminals :: Map.Map String Domain,
  terminals :: [String],
  start :: String,
  rules :: [Rule]
}

weights_to_json_h :: WeightsH x -> (x -> JSON) -> JSON
weights_to_json_h (WeightsData p) f = f p
weights_to_json_h (WeightsDims ws) f = weights_to_json_h ws (JSarray . map f)

weights_to_json :: Weights -> JSON
weights_to_json ws = weights_to_json_h ws JSdouble

instance Functor WeightsH where
  fmap f (WeightsData x) = WeightsData $ f x
  fmap f (WeightsDims x) = WeightsDims $ fmap (map f) x
  

join_list :: Show a => [a] -> String
join_list [] = ""
join_list (a : []) = show a
join_list (a : as) = show a ++ "," ++ join_list as

join_dict :: Show a => [(String, a)] -> String
join_dict [] = ""
join_dict ((k, v) : []) = show k ++ ":" ++ show v
join_dict ((k, v) : kvs) = show k ++ ":" ++ show v ++ "," ++ join_dict kvs


fgg_to_json :: FGG_JSON -> JSON
fgg_to_json (FGG_JSON ds fs nts ts s rs) =
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
               ("nodes", JSarray $ map JSstring ns),
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

emptyFGG :: String -> FGG_JSON
emptyFGG s = FGG_JSON Map.empty Map.empty Map.empty [] s []

  
getWeights :: (Var -> Int) -> Domain -> Weights
getWeights g tps = h g (reverse tps) (WeightsData 1) where
  h :: (Var -> Int) -> Domain -> WeightsH x -> WeightsH x
  h g [] ws = ws
  h g (tp : tps) ws =
    let num_values = g tp in
      WeightsDims $ h g tps (fmap (replicate num_values) ws)

addRule' :: (Var -> [Var]) -> Rule -> FGG_JSON -> FGG_JSON
addRule' getValues r (FGG_JSON ds fs nts ts s rs) =
  let (Rule lhs (HGF ns es xs)) = r
      lookup_nodes = map $ \ i -> ns !! i
      dom = lookup_nodes xs
      ts' = if elem lhs ts then ts else (lhs : ts)
      ds' = foldr (\ n -> Map.insert n (getValues n)) ds ns
      fs' = foldr (\ (Edge atts l) -> if elem l ts' then id else Map.insert l (lookup_nodes atts, getWeights (length . getValues) (lookup_nodes atts))) fs es
      nts' = Map.insert lhs dom nts in
    FGG_JSON ds' fs' nts' ts' s (rs ++ [r])

-- TODO: Ctxt is wrong. We should instead use addRule'
--       with some function that maps a node (edge?)
--       name to a list of its possible values
--       (attached node names?)
addRule :: Ctxt -> Rule -> FGG_JSON -> FGG_JSON
addRule g = addRule' (maybe [] (map $ \ (Ctor x as) -> x) . ctxtLookupType g)




example_ctxt :: Ctxt
example_ctxt = ctxtDeclType (ctxtDeclType emptyCtxt "W" (map (\ x -> Ctor x []) ["the", "cat", "sat", "on", "mat"])) "T" (map (\ x -> Ctor x []) ["DT", "NN", "VBD", "IN", "BOS", "EOS"])

example_rule1 = Rule "S"
  (HGF ["T"] [Edge [0] "is_bos",
              Edge [0] "X"] [])
example_rule2 = Rule "X"
  (HGF ["T", "T", "W"] [Edge [0, 1] "transition",
                        Edge [1, 2] "emission",
                        Edge [1] "X"] [0])
example_rule3 = Rule "X"
  (HGF ["T", "T"] [Edge [0, 1] "transition",
                   Edge [1] "is_eos"] [0])

example_fgg :: FGG_JSON
example_fgg =
  foldr (addRule example_ctxt) (emptyFGG "S") [example_rule1, example_rule2, example_rule3]

{-
example_fgg :: FGG_JSON
example_fgg = FGG_JSON
  (Map.fromList [("T", ["DT", "NN", "VBD", "IN", "BOS", "EOS"]), ("W", ["the", "cat", "sat", "on", "mat"])])
  (Map.fromList [("transition", (["T", "T"], WeightsDims (WeightsDims (WeightsData [[0, 1, 0, 0, 0, 0],[0, 0.25, 0.25, 0.25, 0, 0.25],[0.3, 0, 0, 0.3, 0, 0.4],[1, 0, 0, 0, 0, 0],[0.8, 0, 0, 0.2, 0, 0],[0, 0, 0, 0, 0, 0]])))),
                 ("emission", (["T", "W"], WeightsDims (WeightsDims (WeightsData [[1, 0, 0, 0, 0], [0, 0.5, 0, 0, 0.5], [0, 0, 1, 0, 0], [0, 0, 0, 1, 0], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0]])))),
                 ("is_bos", (["T"], WeightsDims (WeightsData [0, 0, 0, 0, 1, 0]))),
                 ("is_eos", (["T"], WeightsDims (WeightsData [0, 0, 0, 0, 0, 1])))])
  (Map.fromList [("S", []), ("X", ["T"])])
  "S"
  [Rule "S" (HGF ["T"] [Edge [0] "is_bos", Edge [0] "X"] []),
   Rule "X" (HGF ["T", "T", "W"] [Edge [0, 1] "transition", Edge [1, 2] "emission", Edge [1] "X"] [0]),
   Rule "X" (HGF ["T", "T"] [Edge [0, 1] "transition", Edge [1] "is_eos"] [0])]
-}

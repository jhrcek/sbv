-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.SMT.SMT
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Abstraction of SMT solvers
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DefaultSignatures   #-}

module Data.SBV.SMT.SMT (
       -- * Model extraction
         Modelable(..)
       , SatModel(..), genParse
       , extractModels, getModelValues
       , getModelDictionaries, getModelUninterpretedValues
       , displayModels, showModel

       -- * Prover Engines
       , standardEngine
       , standardModel
       , standardSolver

       -- * Results of various tasks
       , ThmResult(..)
       , SatResult(..)
       , AllSatResult(..)
       , SafeResult(..)
       , OptimizeResult(..)
       )
       where

import qualified Control.Exception as C

import Control.Concurrent (newEmptyMVar, takeMVar, putMVar, forkIO)
import Control.DeepSeq    (NFData(..))
import Control.Monad      (when, zipWithM)
import Data.Char          (isSpace)
import Data.Int           (Int8, Int16, Int32, Int64)
import Data.Function      (on)
import Data.List          (intercalate, isPrefixOf, isInfixOf, sortBy)
import Data.Word          (Word8, Word16, Word32, Word64)
import System.Directory   (findExecutable)
import System.Environment (getEnv)
import System.Exit        (ExitCode(..))
import System.IO          (hClose, hFlush, hPutStr, hGetContents, hGetLine)
import System.Process     (runInteractiveProcess, waitForProcess, terminateProcess)

import qualified Data.Map as M

import Data.SBV.Core.AlgReals
import Data.SBV.Core.Data
import Data.SBV.Core.Symbolic (SMTEngine, QueryContext, runQuery, getProofMode, inNonInteractiveProofMode, switchToInteractiveMode)

import Data.SBV.Control.Types

import Data.SBV.SMT.SMTLib    (interpretSolverOutput, interpretSolverModelLine, interpretSolverObjectiveLine)

import Data.SBV.Utils.PrettyNum
import Data.SBV.Utils.Lib             (joinArgs, splitArgs)
import Data.SBV.Utils.TDiff

-- | Extract the final configuration from a result
resultConfig :: SMTResult -> SMTConfig
resultConfig (Unsatisfiable c _) = c
resultConfig (Satisfiable   c _) = c
resultConfig (SatExtField   c _) = c
resultConfig (Unknown       c _) = c
resultConfig (ProofError    c _) = c
resultConfig (TimeOut       c  ) = c

-- | A 'prove' call results in a 'ThmResult'
newtype ThmResult    = ThmResult    SMTResult

-- | A 'sat' call results in a 'SatResult'
-- The reason for having a separate 'SatResult' is to have a more meaningful 'Show' instance.
newtype SatResult    = SatResult    SMTResult

-- | An 'allSat' call results in a 'AllSatResult'. The boolean says whether
-- we should warn the user about prefix-existentials.
newtype AllSatResult = AllSatResult (Bool, [SMTResult])

-- | A 'safe' call results in a 'SafeResult'
newtype SafeResult   = SafeResult   (Maybe String, String, SMTResult)

-- | An 'optimize' call results in a 'OptimizeResult'. In the 'ParetoResult' case, the boolean is 'True'
-- if we reached pareto-query limit and so there might be more unqueried results remaining. If 'False',
-- it means that we have all the pareto fronts returned. See the 'Pareto' 'OptimizeStyle' for details.
data OptimizeResult = LexicographicResult SMTResult
                    | ParetoResult        Bool [SMTResult]
                    | IndependentResult   [(String, SMTResult)]

-- User friendly way of printing theorem results
instance Show ThmResult where
  show (ThmResult r) = showSMTResult "Q.E.D."
                                     "Unknown"     "Unknown. Potential counter-example:\n"
                                     "Falsifiable" "Falsifiable. Counter-example:\n" "Falsifiable in an extension field:\n" r

-- User friendly way of printing satisfiablity results
instance Show SatResult where
  show (SatResult r) = showSMTResult "Unsatisfiable"
                                     "Unknown"     "Unknown. Potential model:\n"
                                     "Satisfiable" "Satisfiable. Model:\n" "Satisfiable in an extension field. Model:\n" r

-- User friendly way of printing safety results
instance Show SafeResult where
   show (SafeResult (mbLoc, msg, r)) = showSMTResult (tag "No violations detected")
                                                     (tag "Unknown")  (tag "Unknown. Potential violating model:\n")
                                                     (tag "Violated") (tag "Violated. Model:\n") (tag "Violated in an extension field:\n") r
        where loc   = maybe "" (++ ": ") mbLoc
              tag s = loc ++ msg ++ ": " ++ s

-- The Show instance of AllSatResults. Note that we have to be careful in being lazy enough
-- as the typical use case is to pull results out as they become available.
instance Show AllSatResult where
  show (AllSatResult (e, xs)) = go (0::Int) xs
    where uniqueWarn | e    = " (Unique up to prefix existentials.)"
                     | True = ""
          go c (s:ss) = let c'      = c+1
                            (ok, o) = sh c' s
                        in c' `seq` if ok then o ++ "\n" ++ go c' ss else o
          go c []     = case c of
                          0 -> "No solutions found."
                          1 -> "This is the only solution." ++ uniqueWarn
                          _ -> "Found " ++ show c ++ " different solutions." ++ uniqueWarn
          sh i c = (ok, showSMTResult "Unsatisfiable"
                                      "Unknown" "Unknown. Potential model:\n"
                                      ("Solution #" ++ show i ++ ":\nSatisfiable") ("Solution #" ++ show i ++ ":\n")
                                      ("Solution $" ++ show i ++ " in an extension field:\n")
                                      c)
              where ok = case c of
                           Satisfiable{} -> True
                           _             -> False

-- Show instance for optimization results
instance Show OptimizeResult where
  show res = case res of
               LexicographicResult r   -> sh id r

               IndependentResult   rs  -> multi "objectives" (map (uncurry shI) rs)

               ParetoResult  False  [r] -> sh (\s -> "Unique pareto front: " ++ s) r
               ParetoResult  False  rs  -> multi "pareto optimal values" (zipWith shP [(1::Int)..] rs)
               ParetoResult  True   rs  ->    multi "pareto optimal values" (zipWith shP [(1::Int)..] rs)
                                          ++ "\n*** Note: Pareto-front extraction was terminated before stream was ended as requested by the user."
                                          ++ "\n***       There might be other (potentially infinitely more) results."

       where multi w [] = "There are no " ++ w ++ " to display models for."
             multi _ xs = intercalate "\n" xs

             shI n = sh (\s -> "Objective "     ++ show n ++ ": " ++ s)
             shP i = sh (\s -> "Pareto front #" ++ show i ++ ": " ++ s)

             sh tag = showSMTResult (tag "Unsatisfiable.")
                                    (tag "Unknown.")
                                    (tag "Unknown. Potential model:" ++ "\n")
                                    (tag "Optimal with no assignments.")
                                    (tag "Optimal model:" ++ "\n")
                                    (tag "Optimal in an extension field:" ++ "\n")

-- | Instances of 'SatModel' can be automatically extracted from models returned by the
-- solvers. The idea is that the sbv infrastructure provides a stream of 'CW''s (constant-words)
-- coming from the solver, and the type @a@ is interpreted based on these constants. Many typical
-- instances are already provided, so new instances can be declared with relative ease.
--
-- Minimum complete definition: 'parseCWs'
class SatModel a where
  -- | Given a sequence of constant-words, extract one instance of the type @a@, returning
  -- the remaining elements untouched. If the next element is not what's expected for this
  -- type you should return 'Nothing'
  parseCWs  :: [CW] -> Maybe (a, [CW])
  -- | Given a parsed model instance, transform it using @f@, and return the result.
  -- The default definition for this method should be sufficient in most use cases.
  cvtModel  :: (a -> Maybe b) -> Maybe (a, [CW]) -> Maybe (b, [CW])
  cvtModel f x = x >>= \(a, r) -> f a >>= \b -> return (b, r)

  default parseCWs :: Read a => [CW] -> Maybe (a, [CW])
  parseCWs (CW _ (CWUserSort (_, s)) : r) = Just (read s, r)
  parseCWs _                              = Nothing

-- | Parse a signed/sized value from a sequence of CWs
genParse :: Integral a => Kind -> [CW] -> Maybe (a, [CW])
genParse k (x@(CW _ (CWInteger i)):r) | kindOf x == k = Just (fromIntegral i, r)
genParse _ _                                          = Nothing

-- | Base case for 'SatModel' at unit type. Comes in handy if there are no real variables.
instance SatModel () where
  parseCWs xs = return ((), xs)

-- | 'Bool' as extracted from a model
instance SatModel Bool where
  parseCWs xs = do (x, r) <- genParse KBool xs
                   return ((x :: Integer) /= 0, r)

-- | 'Word8' as extracted from a model
instance SatModel Word8 where
  parseCWs = genParse (KBounded False 8)

-- | 'Int8' as extracted from a model
instance SatModel Int8 where
  parseCWs = genParse (KBounded True 8)

-- | 'Word16' as extracted from a model
instance SatModel Word16 where
  parseCWs = genParse (KBounded False 16)

-- | 'Int16' as extracted from a model
instance SatModel Int16 where
  parseCWs = genParse (KBounded True 16)

-- | 'Word32' as extracted from a model
instance SatModel Word32 where
  parseCWs = genParse (KBounded False 32)

-- | 'Int32' as extracted from a model
instance SatModel Int32 where
  parseCWs = genParse (KBounded True 32)

-- | 'Word64' as extracted from a model
instance SatModel Word64 where
  parseCWs = genParse (KBounded False 64)

-- | 'Int64' as extracted from a model
instance SatModel Int64 where
  parseCWs = genParse (KBounded True 64)

-- | 'Integer' as extracted from a model
instance SatModel Integer where
  parseCWs = genParse KUnbounded

-- | 'AlgReal' as extracted from a model
instance SatModel AlgReal where
  parseCWs (CW KReal (CWAlgReal i) : r) = Just (i, r)
  parseCWs _                            = Nothing

-- | 'Float' as extracted from a model
instance SatModel Float where
  parseCWs (CW KFloat (CWFloat i) : r) = Just (i, r)
  parseCWs _                           = Nothing

-- | 'Double' as extracted from a model
instance SatModel Double where
  parseCWs (CW KDouble (CWDouble i) : r) = Just (i, r)
  parseCWs _                             = Nothing

-- | 'CW' as extracted from a model; trivial definition
instance SatModel CW where
  parseCWs (cw : r) = Just (cw, r)
  parseCWs []       = Nothing

-- | A rounding mode, extracted from a model. (Default definition suffices)
instance SatModel RoundingMode

-- | A list of values as extracted from a model. When reading a list, we
-- go as long as we can (maximal-munch). Note that this never fails, as
-- we can always return the empty list!
instance SatModel a => SatModel [a] where
  parseCWs [] = Just ([], [])
  parseCWs xs = case parseCWs xs of
                  Just (a, ys) -> case parseCWs ys of
                                    Just (as, zs) -> Just (a:as, zs)
                                    Nothing       -> Just ([], ys)
                  Nothing     -> Just ([], xs)

-- | Tuples extracted from a model
instance (SatModel a, SatModel b) => SatModel (a, b) where
  parseCWs as = do (a, bs) <- parseCWs as
                   (b, cs) <- parseCWs bs
                   return ((a, b), cs)

-- | 3-Tuples extracted from a model
instance (SatModel a, SatModel b, SatModel c) => SatModel (a, b, c) where
  parseCWs as = do (a,      bs) <- parseCWs as
                   ((b, c), ds) <- parseCWs bs
                   return ((a, b, c), ds)

-- | 4-Tuples extracted from a model
instance (SatModel a, SatModel b, SatModel c, SatModel d) => SatModel (a, b, c, d) where
  parseCWs as = do (a,         bs) <- parseCWs as
                   ((b, c, d), es) <- parseCWs bs
                   return ((a, b, c, d), es)

-- | 5-Tuples extracted from a model
instance (SatModel a, SatModel b, SatModel c, SatModel d, SatModel e) => SatModel (a, b, c, d, e) where
  parseCWs as = do (a, bs)            <- parseCWs as
                   ((b, c, d, e), fs) <- parseCWs bs
                   return ((a, b, c, d, e), fs)

-- | 6-Tuples extracted from a model
instance (SatModel a, SatModel b, SatModel c, SatModel d, SatModel e, SatModel f) => SatModel (a, b, c, d, e, f) where
  parseCWs as = do (a, bs)               <- parseCWs as
                   ((b, c, d, e, f), gs) <- parseCWs bs
                   return ((a, b, c, d, e, f), gs)

-- | 7-Tuples extracted from a model
instance (SatModel a, SatModel b, SatModel c, SatModel d, SatModel e, SatModel f, SatModel g) => SatModel (a, b, c, d, e, f, g) where
  parseCWs as = do (a, bs)                  <- parseCWs as
                   ((b, c, d, e, f, g), hs) <- parseCWs bs
                   return ((a, b, c, d, e, f, g), hs)

-- | Various SMT results that we can extract models out of.
class Modelable a where
  -- | Is there a model?
  modelExists :: a -> Bool

  -- | Extract assignments of a model, the result is a tuple where the first argument (if True)
  -- indicates whether the model was "probable". (i.e., if the solver returned unknown.)
  getAssignment :: SatModel b => a -> Either String (Bool, b)

  -- | Extract a model dictionary. Extract a dictionary mapping the variables to
  -- their respective values as returned by the SMT solver. Also see `getModelDictionaries`.
  getModelDictionary :: a -> M.Map String CW

  -- | Extract a model value for a given element. Also see `getModelValues`.
  getModelValue :: SymWord b => String -> a -> Maybe b
  getModelValue v r = fromCW `fmap` (v `M.lookup` getModelDictionary r)

  -- | Extract a representative name for the model value of an uninterpreted kind.
  -- This is supposed to correspond to the value as computed internally by the
  -- SMT solver; and is unportable from solver to solver. Also see `getModelUninterpretedValues`.
  getModelUninterpretedValue :: String -> a -> Maybe String
  getModelUninterpretedValue v r = case v `M.lookup` getModelDictionary r of
                                     Just (CW _ (CWUserSort (_, s))) -> Just s
                                     _                               -> Nothing

  -- | A simpler variant of 'getAssignment' to get a model out without the fuss.
  extractModel :: SatModel b => a -> Maybe b
  extractModel a = case getAssignment a of
                     Right (_, b) -> Just b
                     _            -> Nothing

  -- | Extract model objective values, for all optimization goals.
  getModelObjectives :: a -> M.Map String GeneralizedCW

  -- | Extract the value of an objective
  getModelObjectiveValue :: String -> a -> Maybe GeneralizedCW
  getModelObjectiveValue v r = v `M.lookup` getModelObjectives r

  -- | Extract unsat core
  extractUnsatCore :: a -> Maybe [String]

-- | Return all the models from an 'allSat' call, similar to 'extractModel' but
-- is suitable for the case of multiple results.
extractModels :: SatModel a => AllSatResult -> [a]
extractModels (AllSatResult (_, xs)) = [ms | Right (_, ms) <- map getAssignment xs]

-- | Get dictionaries from an all-sat call. Similar to `getModelDictionary`.
getModelDictionaries :: AllSatResult -> [M.Map String CW]
getModelDictionaries (AllSatResult (_, xs)) = map getModelDictionary xs

-- | Extract value of a variable from an all-sat call. Similar to `getModelValue`.
getModelValues :: SymWord b => String -> AllSatResult -> [Maybe b]
getModelValues s (AllSatResult (_, xs)) =  map (s `getModelValue`) xs

-- | Extract value of an uninterpreted variable from an all-sat call. Similar to `getModelUninterpretedValue`.
getModelUninterpretedValues :: String -> AllSatResult -> [Maybe String]
getModelUninterpretedValues s (AllSatResult (_, xs)) =  map (s `getModelUninterpretedValue`) xs

-- | 'ThmResult' as a generic model provider
instance Modelable ThmResult where
  getAssignment      (ThmResult r) = getAssignment r
  modelExists        (ThmResult r) = modelExists r
  getModelDictionary (ThmResult r) = getModelDictionary r
  getModelObjectives (ThmResult r) = getModelObjectives r
  extractUnsatCore   (ThmResult r) = extractUnsatCore   r

-- | 'SatResult' as a generic model provider
instance Modelable SatResult where
  getAssignment      (SatResult r) = getAssignment r
  modelExists        (SatResult r) = modelExists r
  getModelDictionary (SatResult r) = getModelDictionary r
  getModelObjectives (SatResult r) = getModelObjectives r
  extractUnsatCore   (SatResult r) = extractUnsatCore   r

-- | 'SMTResult' as a generic model provider
instance Modelable SMTResult where
  getAssignment (Unsatisfiable _ _) = Left "SBV.getAssignment: Unsatisfiable result"
  getAssignment (Satisfiable _ m)   = Right (False, parseModelOut m)
  getAssignment (SatExtField _ _)   = Left "SBV.getAssignment: The model is in an extension field"
  getAssignment (Unknown _ m)       = Right (True, parseModelOut m)
  getAssignment (ProofError _ s)    = error $ unlines $ "Backend solver complains: " : s
  getAssignment (TimeOut _)         = Left "Timeout"

  modelExists Satisfiable{}   = True
  modelExists Unknown{}       = False -- don't risk it
  modelExists _               = False

  getModelDictionary Unsatisfiable{}   = M.empty
  getModelDictionary (Satisfiable _ m) = M.fromList (modelAssocs m)
  getModelDictionary SatExtField{}     = M.empty
  getModelDictionary (Unknown _ m)     = M.fromList (modelAssocs m)
  getModelDictionary ProofError{}      = M.empty
  getModelDictionary TimeOut{}         = M.empty

  getModelObjectives Unsatisfiable{}   = M.empty
  getModelObjectives (Satisfiable _ m) = M.fromList (modelObjectives m)
  getModelObjectives (SatExtField _ m) = M.fromList (modelObjectives m)
  getModelObjectives (Unknown _ m)     = M.fromList (modelObjectives m)
  getModelObjectives ProofError{}      = M.empty
  getModelObjectives TimeOut{}         = M.empty

  extractUnsatCore (Unsatisfiable _ uc) = uc
  extractUnsatCore Satisfiable{}        = Nothing
  extractUnsatCore SatExtField{}        = Nothing
  extractUnsatCore Unknown{}            = Nothing
  extractUnsatCore ProofError{}         = Nothing
  extractUnsatCore TimeOut{}            = Nothing

-- | Extract a model out, will throw error if parsing is unsuccessful
parseModelOut :: SatModel a => SMTModel -> a
parseModelOut m = case parseCWs [c | (_, c) <- modelAssocs m] of
                   Just (x, []) -> x
                   Just (_, ys) -> error $ "SBV.parseModelOut: Partially constructed model; remaining elements: " ++ show ys
                   Nothing      -> error $ "SBV.parseModelOut: Cannot construct a model from: " ++ show m

-- | Given an 'allSat' call, we typically want to iterate over it and print the results in sequence. The
-- 'displayModels' function automates this task by calling 'disp' on each result, consecutively. The first
-- 'Int' argument to 'disp' 'is the current model number. The second argument is a tuple, where the first
-- element indicates whether the model is alleged (i.e., if the solver is not sure, returing Unknown)
displayModels :: SatModel a => (Int -> (Bool, a) -> IO ()) -> AllSatResult -> IO Int
displayModels disp (AllSatResult (_, ms)) = do
    inds <- zipWithM display [a | Right a <- map (getAssignment . SatResult) ms] [(1::Int)..]
    return $ last (0:inds)
  where display r i = disp i r >> return i

-- | Show an SMTResult; generic version
showSMTResult :: String -> String -> String -> String -> String -> String -> SMTResult -> String
showSMTResult unsatMsg unkMsg unkMsgModel satMsg satMsgModel satExtMsg result = case result of
  Unsatisfiable _ mbUC          -> unsatMsg ++ showUC mbUC
  Satisfiable _ (SMTModel _ []) -> satMsg
  Satisfiable _ m               -> satMsgModel ++ showModel cfg m
  SatExtField _ (SMTModel b _)  -> satExtMsg   ++ showModelDictionary cfg b
  Unknown     _ (SMTModel _ []) -> unkMsg
  Unknown     _ m               -> unkMsgModel ++ showModel cfg m
  ProofError  _ []              -> "*** An error occurred. No additional information available. Try running in verbose mode"
  ProofError  _ ls              -> "*** An error occurred.\n" ++ intercalate "\n" (map ("***  " ++) ls)
  TimeOut     _                 -> "*** Timeout"
 where cfg = resultConfig result

       showUC Nothing   = ""
       showUC (Just []) = dot ++ "[No unsat core received. Have you labeled relevant assertions?]"
       showUC (Just xs) = intercalate "\n" $ (dot ++ "Unsat core:") : map ("  " ++) xs

       dot = case reverse unsatMsg of
               ('.':_) -> " "
               _       -> ". "

-- | Show a model in human readable form. Ignore bindings to those variables that start
-- with "__internal_sbv_" and also those marked as "nonModelVar" in the config; as these are only for internal purposes
showModel :: SMTConfig -> SMTModel -> String
showModel cfg model = showModelDictionary cfg [(n, RegularCW c) | (n, c) <- modelAssocs model]

-- | Show bindings in a generalized model dictionary, tabulated
showModelDictionary :: SMTConfig -> [(String, GeneralizedCW)] -> String
showModelDictionary cfg allVars
   | null allVars
   = "[There are no variables bound by the model.]"
   | null relevantVars
   = "[There are no model-variables bound by the model.]"
   | True
   = intercalate "\n" . display . map shM $ relevantVars
  where relevantVars  = filter (not . ignore) allVars
        ignore (s, _) = "__internal_sbv_" `isPrefixOf` s || isNonModelVar cfg s

        shM (s, RegularCW v) = let vs = shCW cfg v in ((length s, s), (vlength vs, vs))
        shM (s, other)       = let vs = show other in ((length s, s), (vlength vs, vs))

        display svs   = map line svs
           where line ((_, s), (_, v)) = "  " ++ right (nameWidth - length s) s ++ " = " ++ left (valWidth - lTrimRight (valPart v)) v
                 nameWidth             = maximum $ 0 : [l | ((l, _), _) <- svs]
                 valWidth              = maximum $ 0 : [l | (_, (l, _)) <- svs]

        right p s = s ++ replicate p ' '
        left  p s = replicate p ' ' ++ s
        vlength s = case dropWhile (/= ':') (reverse (takeWhile (/= '\n') s)) of
                      (':':':':r) -> length (dropWhile isSpace r)
                      _           -> length s -- conservative

        valPart ""          = ""
        valPart (':':':':_) = ""
        valPart (x:xs)      = x : valPart xs

        lTrimRight = length . dropWhile isSpace . reverse

-- | Show a constant value, in the user-specified base
shCW :: SMTConfig -> CW -> String
shCW = sh . printBase
  where sh 2  = binS
        sh 10 = show
        sh 16 = hexS
        sh n  = \w -> show w ++ " -- Ignoring unsupported printBase " ++ show n ++ ", use 2, 10, or 16."

-- | Helper function to spin off to an SMT solver.
pipeProcess :: SMTConfig -> QueryContext -> String -> [String] -> SMTScript -> (String -> String) -> ([String] -> [SMTResult]) -> ([String] -> [SMTResult]) -> IO [SMTResult]
pipeProcess cfg ctx execName opts script cleanErrs failure success = do
    mbExecPath <- findExecutable execName
    case mbExecPath of
      Nothing      -> return $ failure [ "Unable to locate executable for " ++ show (name (solver cfg))
                                       , "Executable specified: " ++ show execName
                                       ]

      Just execPath -> runSolver cfg ctx execPath opts script cleanErrs failure success
                       `C.catches`
                        [ C.Handler (\(e :: C.ErrorCall)     -> C.throw e)
                        , C.Handler (\(e :: C.SomeException) -> return $ failure [ "Failed to start the external solver:\n" ++ show e
                                                                                 , "Make sure you can start " ++ show execPath
                                                                                 , "from the command line without issues."
                                                                                 ])
                        ]

-- | The standard-model that most SMT solvers should happily work with
standardModel :: (Bool -> [(Quantifier, NamedSymVar)] -> [String] -> SMTModel, SW -> String -> [String])
standardModel = (standardModelExtractor, standardValueExtractor)

-- | Some solvers (Z3) require multiple calls for certain value extractions; as in multi-precision reals. Deal with that here
standardValueExtractor :: SW -> String -> [String]
standardValueExtractor _ l = [l]

-- | A standard post-processor: Reading the lines of solver output and turning it into a model:
standardModelExtractor :: Bool -> [(Quantifier, NamedSymVar)] -> [String] -> SMTModel
standardModelExtractor isSat qinps solverLines = SMTModel { modelObjectives = map snd $ sortByNodeId $ concatMap (interpretSolverObjectiveLine inps) solverLines
                                                          , modelAssocs     = map snd $ sortByNodeId $ concatMap (interpretSolverModelLine     inps) solverLines
                                                          }
         where sortByNodeId :: [(Int, a)] -> [(Int, a)]
               sortByNodeId = sortBy (compare `on` fst)
               inps -- for "sat", display the prefix existentials. For completeness, we will drop
                    -- only the trailing foralls. Exception: Don't drop anything if it's all a sequence of foralls
                    | isSat = map snd $ if all (== ALL) (map fst qinps)
                                        then qinps
                                        else reverse $ dropWhile ((== ALL) . fst) $ reverse qinps
                    -- for "proof", just display the prefix universals
                    | True  = map snd $ takeWhile ((== ALL) . fst) qinps

-- | A standard engine interface. Most solvers follow-suit here in how we "chat" to them..
standardEngine :: String
               -> String
               -> (SMTConfig -> SMTConfig)
               -> ([String] -> Int -> [String])
               -> (Bool -> [(Quantifier, NamedSymVar)] -> [String] -> SMTModel, SW -> String -> [String])
               -> SMTEngine
standardEngine envName envOptName modConfig addTimeOut (extractMap, extractValue) cfgIn ctx isSat mbOptInfo qinps skolemMap pgm = do

    let cfg = modConfig cfgIn

    -- If there's an optimization goal, it better be handled by a custom engine!
    () <- case mbOptInfo of
            Nothing -> return ()
            Just _  -> error $ "SBV.standardEngine: Solver: " ++ show (name (solver cfg)) ++ " doesn't support optimization!"

    execName <-                    getEnv envName     `C.catch` (\(_ :: C.SomeException) -> return (executable (solver cfg)))
    execOpts <- (splitArgs `fmap`  getEnv envOptName) `C.catch` (\(_ :: C.SomeException) -> return (options (solver cfg)))

    let cfg'    = cfg {solver = (solver cfg) {executable = execName, options = maybe execOpts (addTimeOut execOpts) (timeOut cfg)}}
        tweaks  = case solverTweaks cfg' of
                    [] -> ""
                    ts -> unlines $ "; --- user given solver tweaks ---" : ts ++ ["; --- end of user given tweaks ---"]

        cont rm = concatMap extract skolemMap
           where extract (Left s)        = extractValue s $ "(echo \"((" ++ show s ++ " " ++ mkSkolemZero rm (kindOf s) ++ "))\")"
                 extract (Right (s, [])) = extractValue s $ "(get-value (" ++ show s ++ "))"
                 extract (Right (s, ss)) = extractValue s $ "(get-value (" ++ show s ++ concat [' ' : mkSkolemZero rm (kindOf a) | a <- ss] ++ "))"

        script = SMTScript {scriptBody = tweaks ++ pgm, scriptModel = cont (roundingMode cfg)}

        -- standard engines only return one result ever
        wrap x = [x]

    standardSolver cfg' ctx script id (wrap . ProofError cfg') (wrap . interpretSolverOutput cfg' (extractMap isSat qinps))

-- | A standard solver interface. If the solver is SMT-Lib compliant, then this function should suffice in
-- communicating with it.
standardSolver :: SMTConfig -> QueryContext -> SMTScript -> (String -> String) -> ([String] -> [SMTResult]) -> ([String] -> [SMTResult]) -> IO [SMTResult]
standardSolver config ctx script cleanErrs failure success = do
    let msg      = when (verbose config) . putStrLn . ("** " ++)
        smtSolver= solver config
        exec     = executable smtSolver
        opts     = options smtSolver
    msg $ "Calling: " ++ show (exec ++ (if null opts then "" else " ") ++ joinArgs opts)
    case smtFile config of
      Nothing -> return ()
      Just f  -> do msg $ "Saving the generated script in file: " ++ show f
                    writeFile f (scriptBody script ++ intercalate "\n" ("" : optimizeArgs config ++ [satCmd config]))
    rnf script `seq` pipeProcess config ctx exec opts script cleanErrs failure success

-- | A variant of 'readProcessWithExitCode'; except it knows about continuation strings
-- and can speak SMT-Lib2 (just a little).
runSolver :: SMTConfig -> QueryContext -> FilePath -> [String] -> SMTScript -> (String -> String) -> ([String] -> [SMTResult]) -> ([String] -> [SMTResult]) -> IO [SMTResult]
runSolver cfg ctx execPath opts script cleanErrs failure success
 = do let nm  = show (name (solver cfg))
          msg = when (verbose cfg) . mapM_ (putStrLn . ("*** " ++))

          cleanLine  = reverse . dropWhile isSpace . reverse . dropWhile isSpace

      (send, ask, askFull, cleanUp, pid) <- do
                (inh, outh, errh, pid) <- runInteractiveProcess execPath opts Nothing Nothing
                let send l    = hPutStr inh (l ++ "\n") >> hFlush inh

                    -- Send a line, get a line
                    ask l     = send l >> recv
                    recv      = hGetLine outh

                    -- Send a line, get a whole s-expr. We ignore the
                    -- pathetic case that there might be a string with an
                    -- unbalanced parentheses in it..
                    askFull l = send l >> recvFull
                    recvFull  = (intercalate "\n" . reverse) `fmap` go 0 []
                      where go i sofar = do ln <- hGetLine outh
                                            let open  = length $ filter (== '(') ln
                                                close = length $ filter (== ')') ln
                                                need  = i + open - close
                                                acc   = ln : sofar
                                                -- make sure we get *something*
                                                empty = null $ dropWhile isSpace ln
                                            if not empty && need <= 0
                                               then return acc
                                               else go need acc

                    cleanUp ignoreExitCode response
                      = do (ecObtained, contents, allErrors) <- do
                                      hClose inh
                                      outMVar <- newEmptyMVar
                                      out <- hGetContents outh
                                      _ <- forkIO $ C.evaluate (length out) >> putMVar outMVar ()
                                      err <- hGetContents errh
                                      _ <- forkIO $ C.evaluate (length err) >> putMVar outMVar ()
                                      takeMVar outMVar
                                      takeMVar outMVar
                                      hClose outh
                                      hClose errh
                                      ex <- waitForProcess pid

                                      msg $   [ "Solver   : " ++ nm
                                              , "Exit code: " ++ show ex
                                              ]
                                           ++ case response of
                                                Nothing      -> []
                                                Just (r, vs) ->   ("Response : " ++ r)
                                                                : ["           " ++ l  | l <- vs]
                                           ++ [ "Output   : " ++ out | not (null out)]
                                           ++ [ "Std-err  : " ++ err | not (null err)]

                                      -- Massage the output, preparing for the possibility of not having a model
                                      -- TBD: This is rather crude and potentially Z3 specific
                                      return $ case response of
                                                 Nothing        -> (ex, out, err)
                                                 Just (r, vals) -> let finalOut = intercalate "\n" (r:vals)
                                                                       notAvail = "model is not available" `isInfixOf` (finalOut ++ out ++ err)
                                                                   in if "unknown" `isPrefixOf` r && notAvail
                                                                      then (ExitSuccess, "unknown"              , "")
                                                                      else (ex,          finalOut ++ "\n" ++ out, err)

                           -- If we're told to ignore the exit code, then ignore it
                           let ec | ignoreExitCode = ExitSuccess
                                  | True           = ecObtained

                           let errors = dropWhile isSpace (cleanErrs allErrors)

                           case (null errors, ec) of
                             (True, ExitSuccess)  -> return $ success $ mergeSExpr $ map cleanLine (filter (not . null) (lines contents))
                             (_,    ec')          -> let errors' = filter (not . null) $ lines $ if null errors
                                                                                                 then (if null (dropWhile isSpace contents)
                                                                                                       then "(No error message printed on stderr by the executable.)"
                                                                                                       else contents)
                                                                                                 else errors
                                                         finalEC = case (ec', ec) of
                                                                     (ExitFailure n, _) -> n
                                                                     (_, ExitFailure n) -> n
                                                                     _                  -> 0 -- can happen if ExitSuccess but there is output on stderr
                                                     in return $ failure $ [ "Failed to complete the call to " ++ nm
                                                                           , "Executable   : " ++ show execPath
                                                                           , "Options      : " ++ joinArgs opts
                                                                           , "Exit code    : " ++ show finalEC
                                                                           , "Solver output: "
                                                                           , replicate 78 '='
                                                                           ]
                                                                           ++ errors'
                                                                           ++ ["Giving up.."]
                return (send, ask, askFull, cleanUp, pid)

      let executeSolver = do mapM_ send (lines (scriptBody script))
                             mapM_ send (optimizeArgs cfg)

                             -- Capture what SBV would do here
                             let sbvContinuation ignoreExitCode = do r    <- ask $ satCmd cfg

                                                                     let getUnsatCores = or [b | ProduceUnsatCores b <- solverSetOptions cfg]

                                                                     vals <- case () of
                                                                                () | any (`isPrefixOf` r) ["sat", "unknown"]
                                                                                   -> do let mls = scriptModel script
                                                                                         when (verbose cfg) $ do putStrLn "** Sending the following model extraction commands:"
                                                                                                                 mapM_ putStrLn mls
                                                                                         mapM ask mls
                                                                                () | getUnsatCores && "unsat" `isPrefixOf` r
                                                                                   -> do when (verbose cfg) $ putStrLn "** Querying for unsat cores"
                                                                                         mapM ask ["(get-unsat-core)"]
                                                                                () -> return []
                                                                     cleanUp ignoreExitCode $ Just (r, vals)

                             -- Ask for a model. We assume this is done when we're in a check-sat/sat situation.
                             let askModel = do let mls = scriptModel script
                                               when (verbose cfg) $ do putStrLn "** Sending the following model extraction commands:"
                                                                       mapM_ putStrLn mls
                                               vals <- mapM askFull mls
                                               when (verbose cfg) $ do putStrLn "** Received the following responses:"
                                                                       mapM_ putStrLn vals
                                               return $ success $ mergeSExpr $ "sat" : map cleanLine (filter (not . null) vals)

                             -- If we're given a custom continuation and we're in a proof context, call it. Otherwise execute
                             k <- case (inNonInteractiveProofMode (contextState ctx), customQuery cfg) of
                                    (True, Just q) -> do
                                        when (verbose cfg) $ putStrLn "** Custom query is requested. Giving control to the user."
                                        let interactiveCtx = ctx { contextState = switchToInteractiveMode (contextState ctx) }
                                            qs = QueryState { queryAsk                 = askFull
                                                            , queryConfig              = cfg
                                                            , queryContext             = interactiveCtx
                                                            , queryDefault             = sbvContinuation
                                                            , queryGetModel            = askModel
                                                            , queryIgnoreExitCode      = False
                                                            , queryAssertionStackDepth = 0
                                                            }
                                        return $ runQuery q qs
                                    (False, Just _) -> do when (verbose cfg) $
                                                               putStrLn $ "** Skipping the custom query in mode: " ++ show (getProofMode (contextState ctx))
                                                          return (sbvContinuation False)
                                    (_, Nothing)    -> return (sbvContinuation False)

                             -- Off to the races!
                             timeIf (timing cfg) (WorkByProver nm) k

      executeSolver `C.onException`  (terminateProcess pid >> waitForProcess pid)

-- | In case the SMT-Lib solver returns a response over multiple lines, compress them so we have
-- each S-Expression spanning only a single line. We ignore strings that span multiple lines,
-- hopefully that should not be an issue!
mergeSExpr :: [String] -> [String]
mergeSExpr []       = []
mergeSExpr (x:xs)
 | d == 0 = x : mergeSExpr xs
 | True   = let (f, r) = grab d xs in unwords (x:f) : mergeSExpr r
 where d = parenDiff x

       parenDiff :: String -> Int
       parenDiff = go 0
         where go i ""       = i
               go i ('(':cs) = let i'= i+1 in i' `seq` go i' cs
               go i (')':cs) = let i'= i-1 in i' `seq` go i' cs
               go i ('"':cs) = go i (skipString cs)
               go i (_  :cs) = go i cs

       grab i ls
         | i <= 0    = ([], ls)
       grab _ []     = ([], [])
       grab i (l:ls) = let (a, b) = grab (i+parenDiff l) ls in (l:a, b)

       skipString ('\\':'"':cs) = skipString cs
       skipString ('"':'"':cs)  = skipString cs
       skipString ('"':cs)      = cs
       skipString (_:cs)        = skipString cs
       skipString []            = []             -- Oh dear, line finished, but the string didn't. We're in trouble. Ignore!
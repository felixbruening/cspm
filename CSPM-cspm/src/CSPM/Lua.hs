----------------------------------------------------------------------------
-- |
-- Module      :  CSPM.Lua
-- Copyright   :  (c) Fontaine 2011
-- License     :  BSD3
--
-- Maintainer  :  Fontaine@cs.uni-duesseldorf.de
-- Stability   :  experimental
-- Portability :  GHC-only
--
-- A Lua interface for the CSPM tool.
----------------------------------------------------------------------------
{-# Language DeriveDataTypeable #-}
{-# Language ViewPatterns, RecordWildCards #-}
{-# Language ScopedTypeVariables, RankNTypes, GADTs, KindSignatures #-}
{-# Language FlexibleInstances #-}
module CSPM.Lua
(
  runLua
)
where

import CSPM.Interpreter as Interpreter

import CSPM.LTS.MkLtsPar (mkLtsPar)
import CSPM.CoreLanguage.Event
import CSPM.FiringRules.Rules
import CSPM.FiringRules.FieldConstraints (computeTransitions)
import CSPM.FiringRules.Verifier (viewRule)


import Scripting.LuaUtils
import qualified Scripting.Lua as Lua

import Foreign.StablePtr
import Control.Exception.Base
import Data.Dynamic
import System.Environment
import Control.Monad
import Data.List as List
import Data.Maybe

runLua :: String -> String -> [String] -> IO ()
runLua src chunkName args = bracket (Lua.newstate) (Lua.close) $ \l -> do
  Lua.openlibs l
  registerHsFunctions l exportList
  loadRes <- fmap fromIntegral $ Lua.loadstring l src chunkName
  if loadRes /= 0 then do
      err <- Lua.peek l 1
      case err of
        Nothing -> throwIO $ ErrorFromLua loadRes "Lua.loadstring failed"
        Just msg -> throwIO $ ErrorFromLua loadRes msg
    else do
      Lua.push l $ LuaArray args
      Lua.setglobal l "arg"
      forM_ args $ Lua.push l
      err <- call_debug l (length args) (Just 0)
      maybe (return ()) throwIO err

exportList :: [Export]
exportList =
  [ luaHsExports
  , luaExportInfo
  , luaToString
  , luaTypeOf
  , luaEval
  , luaMakeLTS
  , Export "rawCmdArgs"     "get the raw list of command args "   (fmap LuaArray getArgs)
  , luaTransitions
  , luaValueToProcess
  , luaViewProofTree
  ]
  where 
    returnIO :: a -> IO a
    returnIO = return

luaExportInfo :: Export
luaExportInfo = Export "exportInfo" "information about exported functions"
    $ (return helpMsg :: IO String)
  where
    helpMsg = concat [
      "Lua API for CSPM",nl
     ,"Haskell exported functions :" ,nl
     ] ++ concatMap mkFunMsg exportList
    nl = "\n"
    mkFunMsg Export {..} = concat [
       " * " , exportName ," : ",nl
      ,"     ", exportHelp ,nl
      ]

luaHsExports :: Export
luaHsExports = Export "hsExports" "return a table with all exported functions"
    (return $ LuaArray $ map exportName exportList :: IO (LuaArray String))
  where exportName (Export n _ _) = "_cspm_" ++ n

luaToString :: Export
luaToString = Export "toString" "convert an Object to a String" fkt
  where
    fkt :: LuaObject -> IO (LuaReturn String)
    fkt ptr = handleException $ do
      dyn <- deRefStablePtr $ castPtrToStablePtr ptr
      return $ case dyn of
        (fromDynamic -> Just (v :: Interpreter.Value)) -> show v
        (fromDynamic -> Just (v :: Interpreter.Process)) -> show v
        (fromDynamic -> Just (LuaError err)) -> show err
        (fromDynamic -> Just (e :: (TTE INT))) -> showTTE e
        _ -> "val:" ++ (show $ dynTypeRep dyn)

luaTypeOf :: Export
luaTypeOf = Export "reflectType" "get the type of an Object" fkt
  where
    fkt :: LuaObject -> IO (LuaReturn String)
    fkt ptr = handleException $ do
      typeRep <- fmap dynTypeRep $ deRefStablePtr $ castPtrToStablePtr ptr
      case List.lookup typeRep shortTypes of
        Just t -> return t
        Nothing -> return $ show typeRep
    shortTypes = [
--      (typeOf (undefined :: LuaValue),       "Value")
--     ,(typeOf (undefined :: LuaTransition ), "Transistion")
--     ,(typeOf (undefined :: LuaEvent ),      "Event")
--     (typeOf (undefined :: LuaLTS ),        "LTS")
     ]


luaEval :: Export
luaEval = Export "eval"
  "eval an expression in the context of an specification" fkt
  where
    fkt :: Bool -> Maybe String -> String -> IO (LuaReturn AssocTable)
    fkt verbose spec expr = handleException $ do
       (value,env) <- evalString verbose (fromMaybe "spec" spec) "spec from lua" expr
       lValue <- toLuaObject value
       lEnv <- toLuaObject env
       lSigma <- toLuaObject $ getSigma env
       return $ AssocTable
         [ "value" :-> lValue
         , "env" :-> lEnv
         , "sigma" :-> lSigma]

luaMakeLTS :: Export
luaMakeLTS = Export "makeLTS" "compute the LTS of a Process" fkt
  where
    fkt :: LuaObject -> LuaObject -> IO (LuaReturn LuaObject)
    fkt lSigma lProc = handleException $ do
      (sigma :: Interpreter.ClosureSet) <- fromLuaObject lSigma
      proc <- fromLuaObject lProc
      toLuaObject $ mkLtsPar sigma proc

luaValueToProcess :: Export
luaValueToProcess = Export "valueToProcess" "cast a Value to a Process" fkt
  where
    fkt :: LuaObject -> IO (LuaReturn LuaObject)
    fkt a = do
      val <- fromLuaObject a
      case val of
        VProcess p -> fmap LuaReturnOK $ toLuaObject p
        _ -> error "typeError expecting VProcess"

luaTransitions :: Export
luaTransitions = Export
    "transitions"
    "compute the transitions of a Process"
    fkt
  where
    fkt :: LuaObject -> LuaObject -> IO (LuaReturn (LuaArray LuaObject))
    fkt lSigma lProc = handleException $ do
      (sigma :: Interpreter.ClosureSet) <- fromLuaObject lSigma
      proc <- fromLuaObject lProc
      let (proofs :: [Rule INT]) = computeTransitions sigma proc
      fmap LuaArray $ mapM toLuaObject proofs

luaViewProofTree :: Export
luaViewProofTree = Export
    "viewProofTree"
    "compute (PrevState,Event,SuccState)"
    fkt
  where
    fkt :: LuaObject -> IO (LuaReturn AssocTable)
    fkt t = handleException $ do
      (rule :: Rule INT) <- fromLuaObject t
      let (a, event ,b) = viewRule rule
      lA <- toLuaObject a
      lEvent <- toLuaObject event
      lB <- toLuaObject b
      return $ AssocTable
        [ "predState" :-> lA
        , "event" :-> lEvent
        , "succState" :-> lB]

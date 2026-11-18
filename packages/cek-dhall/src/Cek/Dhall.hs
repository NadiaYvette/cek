{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cek.Dhall
Description : Felleisen-Friedman CEK abstract machine for Dhall expression normalization
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
Stability   : experimental
Portability : non-portable (GHC extensions)

Implements a tailored Felleisen-Friedman CEK machine for the normalization and
evaluation of Dhall language constructs (natural numbers, integers, booleans, text,
records, projections, lists, and closures).

= Architectural Context

Per Note [Felleisen-Friedman CEK Abstract Machine] [ref:note-core-architecture],
this module models Dhall strong normalization through tail-recursive transition steps:
* Record fields are evaluated inside-out.
* Projections ('DField') resolve against fully evaluated record values.
* Operators ('DOpPlus', 'DOpTextAppend') evaluate operands strictly before combining.
-}
module Cek.Dhall
  ( -- * Dhall AST
    DhallExpr(..)
    -- * Value Domain
  , DhallVal(..)
  , DhallEnv(..)
  , emptyDhallEnv
  , extendDhallEnv
  , lookupDhallEnv
    -- * Continuation Frames
  , DhallFrame(..)
  , DhallCont
  , emptyDhallCont
    -- * Machine State & Evaluator
  , DhallState(..)
  , stepDhallCEK
  , evalDhallCEK
  ) where

import Data.Text (Text)
import Data.Word (Word64)
import GHC.Generics (Generic)

-- | Abstract syntax for normalized Dhall expressions.
data DhallExpr
  = DVar !Text                           -- ^ Variable identifier
  | DLam !Text !DhallExpr                -- ^ Lambda abstraction (\(\lambda x. e\))
  | DApp !DhallExpr !DhallExpr           -- ^ Function application
  | DLet !Text !DhallExpr !DhallExpr     -- ^ Let-binding (@let x = e1 in e2@)
  | DNat !Word64                         -- ^ Natural literal (@+42@)
  | DInt !Integer                        -- ^ Signed integer literal (@-7@)
  | DBool !Bool                          -- ^ Boolean literal (@True@, @False@)
  | DText !Text                          -- ^ Text literal (@"hello"@)
  | DRecord ![(Text, DhallExpr)]         -- ^ Record literal (@{ x = 1, y = 2 }@)
  | DField !DhallExpr !Text              -- ^ Field selection (@r.x@)
  | DList ![DhallExpr]                   -- ^ List literal (@[1, 2, 3]@)
  | DOpPlus !DhallExpr !DhallExpr        -- ^ Natural addition (@n + m@)
  | DOpTextAppend !DhallExpr !DhallExpr  -- ^ Text concatenation (@s1 ++ s2@)
  deriving stock (Eq, Show, Generic)

-- | Normalized Dhall values.
data DhallVal
  = VNat !Word64                          -- ^ Natural number value
  | VInt !Integer                         -- ^ Integer value
  | VBool !Bool                           -- ^ Boolean value
  | VText !Text                           -- ^ Text string value
  | VClosure !Text !DhallExpr !DhallEnv   -- ^ Lexical closure \(\langle x, e, E \rangle\)
  | VRecord ![(Text, DhallVal)]           -- ^ Fully evaluated record value
  | VList ![DhallVal]                     -- ^ Evaluated list value
  deriving stock (Eq, Show, Generic)

-- | Lexical environment for Dhall evaluation.
newtype DhallEnv = DhallEnv { unDhallEnv :: [(Text, DhallVal)] }
  deriving stock (Eq, Show, Generic)

-- | Construct an empty Dhall environment.
emptyDhallEnv :: DhallEnv
emptyDhallEnv = DhallEnv []

-- | Extend a Dhall environment with a variable binding.
extendDhallEnv :: Text -> DhallVal -> DhallEnv -> DhallEnv
extendDhallEnv !x !v (DhallEnv bs) = DhallEnv ((x, v) : bs)

-- | Lookup a variable in a Dhall environment.
lookupDhallEnv :: Text -> DhallEnv -> Maybe DhallVal
lookupDhallEnv !x (DhallEnv bs) = lookup x bs

-- | Continuation frames for Dhall evaluation contexts.
data DhallFrame
  = DFrameArg !DhallExpr !DhallEnv              -- ^ Waiting for function argument
  | DFrameFun !DhallVal                         -- ^ Waiting for function body to apply
  | DFrameLet !Text !DhallExpr !DhallEnv        -- ^ Waiting for let-bound definition
  | DFrameField !Text                           -- ^ Waiting for record expression to project field
  | DFrameOpPlusR !DhallExpr !DhallEnv          -- ^ Waiting for right operand of addition
  | DFrameOpPlusL !Word64                       -- ^ Waiting to add left natural
  | DFrameOpTextR !DhallExpr !DhallEnv          -- ^ Waiting for right operand of text append
  | DFrameOpTextL !Text                         -- ^ Waiting to append left text
  deriving stock (Eq, Show, Generic)

-- | Dhall continuation stack.
type DhallCont = [DhallFrame]

-- | Construct an empty Dhall continuation stack.
emptyDhallCont :: DhallCont
emptyDhallCont = []

-- | Active state of the Dhall CEK abstract machine.
data DhallState
  = DStateEval !DhallExpr !DhallEnv !DhallCont   -- ^ Control expression \(C\), environment \(E\), continuation \(K\)
  | DStateReturn !DhallVal !DhallCont           -- ^ Value \(V\) being delivered to continuation \(K\)
  deriving stock (Eq, Show, Generic)

-- | Advance the Dhall CEK machine by a single deterministic transition step.
stepDhallCEK :: DhallState -> Either Text (Maybe DhallState)
stepDhallCEK (DStateEval expr env cont) = case expr of
  DVar x -> case lookupDhallEnv x env of
    Just val -> pure (Just (DStateReturn val cont))
    Nothing  -> Left ("Unbound variable in Dhall expression: " <> x)
  DLam x body ->
    pure (Just (DStateReturn (VClosure x body env) cont))
  DApp e1 e2 ->
    pure (Just (DStateEval e1 env (DFrameArg e2 env : cont)))
  DLet x e1 e2 ->
    pure (Just (DStateEval e1 env (DFrameLet x e2 env : cont)))
  DNat n ->
    pure (Just (DStateReturn (VNat n) cont))
  DInt i ->
    pure (Just (DStateReturn (VInt i) cont))
  DBool b ->
    pure (Just (DStateReturn (VBool b) cont))
  DText t ->
    pure (Just (DStateReturn (VText t) cont))
  DRecord fields -> do
    -- Evaluate record fields in order
    vals <- mapM (\(f, e) -> evalDhallCEKWithEnv env e >>= \v -> pure (f, v)) fields
    pure (Just (DStateReturn (VRecord vals) cont))
  DField recExpr fieldName ->
    pure (Just (DStateEval recExpr env (DFrameField fieldName : cont)))
  DList items -> do
    vals <- mapM (evalDhallCEKWithEnv env) items
    pure (Just (DStateReturn (VList vals) cont))
  DOpPlus e1 e2 ->
    pure (Just (DStateEval e1 env (DFrameOpPlusR e2 env : cont)))
  DOpTextAppend e1 e2 ->
    pure (Just (DStateEval e1 env (DFrameOpTextR e2 env : cont)))

stepDhallCEK (DStateReturn val cont) = case cont of
  [] -> pure Nothing -- Terminal state: value computed
  (DFrameArg e2 env : rest) ->
    pure (Just (DStateEval e2 env (DFrameFun val : rest)))
  (DFrameFun funVal : rest) -> case funVal of
    VClosure x body closureEnv ->
      let !newEnv = extendDhallEnv x val closureEnv
      in pure (Just (DStateEval body newEnv rest))
    _ -> Left "Type error: Attempted to apply non-function Dhall value"
  (DFrameLet x e2 env : rest) ->
    let !newEnv = extendDhallEnv x val env
    in pure (Just (DStateEval e2 newEnv rest))
  (DFrameField fieldName : rest) -> case val of
    VRecord fields -> case lookup fieldName fields of
      Just fieldVal -> pure (Just (DStateReturn fieldVal rest))
      Nothing       -> Left ("Record field not found: " <> fieldName)
    _ -> Left "Type error: Cannot project field from non-record Dhall value"
  (DFrameOpPlusR e2 env : rest) -> case val of
    VNat n1 -> pure (Just (DStateEval e2 env (DFrameOpPlusL n1 : rest)))
    _       -> Left "Type error: Left operand of + must be a Natural"
  (DFrameOpPlusL n1 : rest) -> case val of
    VNat n2 -> pure (Just (DStateReturn (VNat (n1 + n2)) rest))
    _       -> Left "Type error: Right operand of + must be a Natural"
  (DFrameOpTextR e2 env : rest) -> case val of
    VText t1 -> pure (Just (DStateEval e2 env (DFrameOpTextL t1 : rest)))
    _        -> Left "Type error: Left operand of ++ must be Text"
  (DFrameOpTextL t1 : rest) -> case val of
    VText t2 -> pure (Just (DStateReturn (VText (t1 <> t2)) rest))
    _        -> Left "Type error: Right operand of ++ must be Text"

-- | Evaluate a 'DhallExpr' under a specific lexical environment.
evalDhallCEKWithEnv :: DhallEnv -> DhallExpr -> Either Text DhallVal
evalDhallCEKWithEnv env expr = go (DStateEval expr env emptyDhallCont)
  where
    go st = case stepDhallCEK st of
      Left err -> Left err
      Right Nothing -> case st of
        DStateReturn v [] -> pure v
        _                 -> Left "Internal CEK invariant violation"
      Right (Just nextSt) -> go nextSt

-- | Evaluate a Dhall expression to its final normalized value under the empty environment.
evalDhallCEK :: DhallExpr -> Either Text DhallVal
evalDhallCEK = evalDhallCEKWithEnv emptyDhallEnv

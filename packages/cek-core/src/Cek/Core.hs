{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cek.Core
Description : Foundational Felleisen-Friedman Control-Environment-Continuation (CEK) abstract machine
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
Stability   : experimental
Portability : non-portable (GHC extensions)

Implements the classical Felleisen-Friedman (1986/1987) Control-Environment-Continuation (CEK)
abstract machine for call-by-value evaluation of functional expressions.

= Architectural Context

Per Note [Felleisen-Friedman CEK Abstract Machine] [ref:note-core-architecture],
this module models evaluation state transitions as an explicit 3-tuple \(\langle C, E, K \rangle\):
1. __Control (\(C\)):__ The active term undergoing reduction ('Term').
2. __Environment (\(E\)):__ Lexical scope mapping free variables to values ('Env').
3. __Continuation (\(K\)):__ Explicit evaluation context frames eliminating host stack recursion ('Cont').

= Transitions

* __Variable:__ \(\langle x, E, K \rangle \Longrightarrow \text{applyCont}(K, E(x))\)
* __Abstraction:__ \(\langle \lambda x. e, E, K \rangle \Longrightarrow \text{applyCont}(K, \text{Closure}(x, e, E))\)
* __Application:__ \(\langle e_1 \; e_2, E, K \rangle \Longrightarrow \langle e_1, E, \text{FrameArg}(e_2, E) : K \rangle\)
* __Argument Evaluated:__ \(\text{applyCont}(\text{FrameArg}(e_2, E) : K, v_1) \Longrightarrow \langle e_2, E, \text{FrameFun}(v_1) : K \rangle\)
* __Function Applied:__ \(\text{applyCont}(\text{FrameFun}(\text{Closure}(x, e, E')) : K, v_2) \Longrightarrow \langle e, E'[x \mapsto v_2], K \rangle\)
-}
module Cek.Core
  ( -- * Abstract Syntax
    Term(..)
  , Literal(..)
    -- * Value Domain & Environment
  , Value(..)
  , Env(..)
  , emptyEnv
  , extendEnv
  , lookupEnv
    -- * Continuation Frames
  , Frame(..)
  , Cont
  , emptyCont
    -- * Machine State & Execution
  , CEKState(..)
  , stepCEK
  , evalCEK
  , runCEKWithFuel
  ) where

import Data.Text (Text)
import Data.Word (Word64)
import GHC.Generics (Generic)

-- | Primitive literal values supported by the base CEK machine.
data Literal
  = LitNat !Word64        -- ^ Natural numbers
  | LitInt !Integer       -- ^ Arbitrary-precision integers
  | LitBool !Bool         -- ^ Boolean values
  | LitText !Text         -- ^ Text literals
  deriving stock (Eq, Show, Generic)

-- | Core functional term syntax.
data Term
  = Var !Text             -- ^ Variable identifier
  | Lam !Text !Term       -- ^ Anonymous lambda abstraction (\(\lambda x. e\))
  | App !Term !Term       -- ^ Function application (\(e_1 \; e_2\))
  | Lit !Literal          -- ^ Embedded literal constant
  | Let !Text !Term !Term -- ^ Let-binding (@let x = e1 in e2@)
  deriving stock (Eq, Show, Generic)

-- | Evaluated runtime values.
data Value
  = VClosure !Text !Term !Env -- ^ Lexical closure \(\langle x, e, E \rangle\)
  | VLit !Literal             -- ^ Primitive literal value
  deriving stock (Eq, Show, Generic)

-- | Lexical variable environment mapping identifiers to values.
newtype Env = Env { unEnv :: [(Text, Value)] }
  deriving stock (Eq, Show, Generic)

-- | Construct an empty lexical environment.
emptyEnv :: Env
emptyEnv = Env []

-- | Extend an environment with a new variable-to-value binding.
extendEnv :: Text -> Value -> Env -> Env
extendEnv !var !val (Env bindings) = Env ((var, val) : bindings)

-- | Look up a variable in the environment.
lookupEnv :: Text -> Env -> Maybe Value
lookupEnv !var (Env bindings) = lookup var bindings

-- | Individual continuation frame representing pending reduction context.
data Frame
  = FrameArg !Term !Env       -- ^ Waiting for function argument to evaluate
  | FrameFun !Value           -- ^ Waiting for function body to apply after argument value is ready
  | FrameLet !Text !Term !Env -- ^ Waiting for let-bound variable computation
  deriving stock (Eq, Show, Generic)

-- | Evaluation continuation stack.
type Cont = [Frame]

-- | Construct an initial empty continuation stack.
emptyCont :: Cont
emptyCont = []

-- | Active state of the CEK abstract machine.
data CEKState
  = StateEval !Term !Env !Cont  -- ^ Evaluation state: active control term \(C\), environment \(E\), continuation \(K\)
  | StateReturn !Value !Cont    -- ^ Return state: value \(V\) being passed into continuation stack \(K\)
  deriving stock (Eq, Show, Generic)

-- | Perform a single deterministic step of the CEK abstract machine.
--
-- Returns:
-- * 'Right (Just nextState)' on successful transition.
-- * 'Right Nothing' when execution terminates in a final value.
-- * 'Left err' when a runtime error (e.g. unbound variable, type mismatch) occurs.
stepCEK :: CEKState -> Either Text (Maybe CEKState)
stepCEK (StateEval term env cont) = case term of
  Var x -> case lookupEnv x env of
    Just val -> pure (Just (StateReturn val cont))
    Nothing  -> Left ("Unbound variable in CEK environment: " <> x)
  Lam x body ->
    pure (Just (StateReturn (VClosure x body env) cont))
  Lit lit ->
    pure (Just (StateReturn (VLit lit) cont))
  App e1 e2 ->
    pure (Just (StateEval e1 env (FrameArg e2 env : cont)))
  Let x e1 e2 ->
    pure (Just (StateEval e1 env (FrameLet x e2 env : cont)))

stepCEK (StateReturn val cont) = case cont of
  [] -> pure Nothing -- Terminal state: computation returned final value
  (FrameArg e2 env : restCont) ->
    pure (Just (StateEval e2 env (FrameFun val : restCont)))
  (FrameFun funVal : restCont) -> case funVal of
    VClosure x body closureEnv ->
      let !newEnv = extendEnv x val closureEnv
      in pure (Just (StateEval body newEnv restCont))
    VLit _ ->
      Left "Type error: Attempted to apply non-function literal value"
  (FrameLet x e2 env : restCont) ->
    let !newEnv = extendEnv x val env
    in pure (Just (StateEval e2 newEnv restCont))

-- | Evaluate a 'Term' to a final 'Value' under an empty environment and continuation.
evalCEK :: Term -> Either Text Value
evalCEK term = go (StateEval term emptyEnv emptyCont)
  where
    go st = case stepCEK st of
      Left err -> Left err
      Right Nothing -> case st of
        StateReturn v [] -> pure v
        _                -> Left "Internal CEK invariant violation: Terminal state without return value"
      Right (Just nextSt) -> go nextSt

-- | Fuel-bounded execution of a 'Term', returning either the computed value or fuel exhaustion.
runCEKWithFuel :: Word64 -> Term -> (Either Text Value, Word64)
runCEKWithFuel fuel term = go fuel (StateEval term emptyEnv emptyCont)
  where
    go 0 _ = (Left "OutOfFuel: Execution budget exhausted", 0)
    go !remFuel st = case stepCEK st of
      Left err -> (Left err, remFuel)
      Right Nothing -> case st of
        StateReturn v [] -> (pure v, remFuel)
        _                -> (Left "Internal CEK invariant violation", remFuel)
      Right (Just nextSt) -> go (remFuel - 1) nextSt

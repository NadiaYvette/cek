{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -Wno-pattern-namespace-specifier #-}

-- |
-- Module      : Cek.Examples.Scheme
-- Description : Call-by-Value Scheme interpreter showcasing Generic1 Dissection and O(1) CoW call/cc.
--
-- Demonstrates how a language can combine automatic polynomial functor dissection
-- ('Dissectable' derived via 'Generic1') for uniform left-to-right expression spines
-- with explicit control and state effects ('SCallCC', 'SSet') backed by 'KontStack'
-- and 'SoAStore'.
--
-- === Architecture of the Scheme Showcase
--
-- The Scheme interpreter models R5RS/R7RS Call-by-Value semantics:
--
--   1. Pure syntactic expressions (such as arithmetic operations 'SAdd', 'SSub', 'SMul',
--      comparisons 'SEq', and sequencing 'SSeq') require zero manual frame management:
--      they are evaluated left-to-right automatically by GHC's derived 'Generic1'
--      dissection ('FT_PureDissect').
--   2. Mutable variables (@set!@) manipulate memory cells allocated in the unboxed 'SoAStore'.
--   3. First-class continuations (@call/cc@) capture the entire 32-frame unrolled
--      'KontStack' in strictly $O(1)$ time via Copy-on-Write ('captureKontSoA').
--      Invoking a captured continuation reinstates the execution context immediately
--      ('restoreKontSoA') with zero stack unwinding overhead.
module Cek.Examples.Scheme
  ( -- * Syntax Functors and Trees
    Fix(..)
  , SchemeF(..)
  , SchemeTerm

    -- * Values and Environments
  , SchemeVal(..)
  , SchemeEnv(..)
  , SchemeError(..)

    -- * Continuation Frame Tags
  , pattern FT_SchemeIf
  , pattern FT_SchemeSet
  , pattern FT_SchemeCallCC
  , pattern FT_SchemeAppFn
  , pattern FT_SchemeAppArgs

    -- * Evaluator Entry Point
  , evalScheme
  ) where

import Control.Monad.ST (ST, runST)
import Data.Bits (shiftR, (.&.))
import Data.Int (Int32)
import Data.Primitive.ByteArray (writeByteArray)
import Data.Primitive.SmallArray
  ( SmallArray
  , indexSmallArray
  , readSmallArray
  , sizeofSmallArray
  , smallArrayFromList
  , writeSmallArray
  )
import GHC.Exts (unsafeCoerce#)
import GHC.Generics (Generic1)

import Cek.Core.Dissect (Dissect(..), Dissectable(..))
import Cek.Pykinos.Kont
  ( CapturedKont(..)
  , FrameTag(..)
  , KontStack
  , captureKontSoA
  , newKontStack
  , pattern FT_PureDissect
  , popFrameSoA
  , pushFrameSoA
  , restoreKontSoA
  )
import Cek.Pykinos.Store
  ( SoAStore(..)
  , StoreChunk(..)
  , acquireSlot
  , newSoAStore
  , pattern CT_WRecord
  , unCellTag
  )

-- | Fixed-point wrapper for recursive syntax functors.
newtype Fix f = In { out :: f (Fix f) }

-- | Base pattern functor for the Call-by-Value Scheme showcase calculus.
--
-- Uniform expression nodes ('SAdd', 'SSub', 'SMul', 'SEq', 'SSeq') are handled
-- automatically by the derived 'Generic1' 'Dissectable' instance.
-- Special binding/control forms ('SVar', 'SLam', 'SLet', 'SSet', 'SIf', 'SCallCC', 'SApp')
-- are intercepted in the evaluator before entering generic dissection.
data SchemeF r
  = SLit    !Int32
    -- ^ 32-bit signed integer literal constant.
  | SBool   !Bool
    -- ^ Boolean literal constant (@#t@ or @#f@).
  | SVar    !Int
    -- ^ Lexical variable reference indexed by De Bruijn offset into 'SchemeEnv'.
  | SLam    !Int !r
    -- ^ Lambda abstraction with arity and body term.
  | SLet    !r !r
    -- ^ Let binding @(let ((x rhs)) body)@ desugared to immediate 1-argument application.
  | SSet    !Int !r
    -- ^ Mutable lexical assignment @(set! var rhs)@ mutating the 'SoAStore' cell in place.
  | SIf     !r !r !r
    -- ^ Short-circuiting conditional expression @(if cond thenBranch elseBranch)@.
  | SCallCC !r
    -- ^ First-class continuation reification @(call/cc (lambda (k) ...))@.
  | SApp    !r ![r]
    -- ^ Multi-argument function or continuation application @(fn arg0 arg1 ...)@.
  | SAdd    !r !r
    -- ^ Pure primitive addition @(+ a b)@.
  | SSub    !r !r
    -- ^ Pure primitive subtraction @(- a b)@.
  | SMul    !r !r
    -- ^ Pure primitive multiplication @(* a b)@.
  | SEq     !r !r
    -- ^ Pure primitive equality comparison @(= a b)@.
  | SSeq    !r !r
    -- ^ Sequencing expression @(begin e1 e2)@.
  deriving stock (Show, Functor, Generic1)
  deriving anyclass (Dissectable)

-- | Closed syntax tree for the Scheme calculus.
type SchemeTerm = Fix SchemeF

-- | Lexical environment mapping De Bruijn indices to mutable 'SoAStore' cell addresses.
newtype SchemeEnv = SchemeEnv (SmallArray Int32)

-- | Runtime values of the Scheme abstract machine.
--
-- Note that 'VCont' holds an O(1) copy-on-write snapshot of the 32-frame SoA 'KontStack'.
data SchemeVal s
  = VInt     !Int32
    -- ^ Evaluated integer value.
  | VBool    !Bool
    -- ^ Evaluated boolean truth value.
  | VUnit
    -- ^ Evaluated unit value returned by side-effecting operations like @set!@.
  | VClosure !Int !SchemeTerm !SchemeEnv
    -- ^ Lexical closure capturing arity, AST body, and captured environment.
  | VCont    !(CapturedKont s)
    -- ^ First-class captured continuation snapshot supporting multi-shot resumption.

-- | Terminal outcome or error condition for a fuel-bounded Scheme evaluation.
data SchemeError
  = ErrOutOfFuel
    -- ^ Evaluation step counter reached zero before termination.
  | ErrTypeError !String
    -- ^ Value type did not match expected operator signature.
  | ErrArityMismatch !Int !Int
    -- ^ Actual argument count did not match procedure arity.
  | ErrUnboundVar !Int
    -- ^ Variable De Bruijn index exceeded current lexical environment depth.
  deriving stock (Eq, Show)

-- | Custom continuation frame tags for Scheme special forms in 'KontStack'.
pattern FT_SchemeIf      :: FrameTag
pattern FT_SchemeIf      = FrameTag 40

-- | Frame tag for pending assignment to a variable cell address.
pattern FT_SchemeSet     :: FrameTag
pattern FT_SchemeSet     = FrameTag 41

-- | Frame tag for evaluating the receiver of @call/cc@.
pattern FT_SchemeCallCC  :: FrameTag
pattern FT_SchemeCallCC  = FrameTag 42

-- | Frame tag for evaluating a function term before its arguments.
pattern FT_SchemeAppFn   :: FrameTag
pattern FT_SchemeAppFn   = FrameTag 43

-- | Frame tag for evaluating an argument list spine left-to-right.
pattern FT_SchemeAppArgs :: FrameTag
pattern FT_SchemeAppArgs = FrameTag 44

-- | Allocate a mutable value cell in 'SoAStore' and return its 'Int32' address.
{-# INLINE allocSchemeVal #-}
allocSchemeVal :: SoAStore s -> SchemeVal s -> ST s Int32
allocSchemeVal store !val = do
  (!addr, StoreChunk{..}, !slot) <- acquireSlot store
  writeByteArray scUnboxed slot (unCellTag CT_WRecord)
  writeSmallArray scPtrA slot (unsafeCoerce# val)
  pure addr

-- | Read a 'SchemeVal' from a mutable 'SoAStore' cell address in O(1) time.
{-# INLINE readSchemeVal #-}
readSchemeVal :: SoAStore s -> Int32 -> ST s (SchemeVal s)
readSchemeVal SoAStore{..} !addr = do
  let !ix   = fromIntegral addr :: Int
      !slot = ix .&. 0xFFF
  StoreChunk{..} <- readSmallArray ssChunks (ix `shiftR` 12)
  unsafeCoerce# <$> readSmallArray scPtrA slot

-- | Mutate an existing 'SoAStore' cell in place (implementing Scheme @set!@).
{-# INLINE writeSchemeVal #-}
writeSchemeVal :: SoAStore s -> Int32 -> SchemeVal s -> ST s ()
writeSchemeVal SoAStore{..} !addr !val = do
  let !ix   = fromIntegral addr :: Int
      !slot = ix .&. 0xFFF
  StoreChunk{..} <- readSmallArray ssChunks (ix `shiftR` 12)
  writeSmallArray scPtrA slot (unsafeCoerce# val)

-- | Extend a lexical environment with a list of freshly allocated argument addresses.
extendSchemeEnv :: [Int32] -> SchemeEnv -> SchemeEnv
extendSchemeEnv newAddrs (SchemeEnv oldArr) =
  let !n = sizeofSmallArray oldArr
      !oldList = [indexSmallArray oldArr i | i <- [0 .. n - 1]]
  in SchemeEnv (smallArrayFromList (newAddrs ++ oldList))

-- | Safe index helper for 'SchemeEnv'.
lookupSchemeEnv :: SchemeEnv -> Int -> Maybe Int32
lookupSchemeEnv (SchemeEnv arr) !ix =
  let !n = sizeofSmallArray arr
  in if ix >= 0 && ix < n
       then Just (indexSmallArray arr ix)
       else Nothing

-- | Reduce a fully dissected pure syntax node (all children evaluated to 'SchemeVal').
reducePureScheme :: SchemeF (SchemeVal s) -> Either SchemeError (SchemeVal s)
reducePureScheme = \case
  SLit n -> Right (VInt n)
  SBool b -> Right (VBool b)
  SAdd (VInt a) (VInt b) -> Right (VInt (a + b))
  SSub (VInt a) (VInt b) -> Right (VInt (a - b))
  SMul (VInt a) (VInt b) -> Right (VInt (a * b))
  SEq  (VInt a) (VInt b) -> Right (VBool (a == b))
  SEq  (VBool a) (VBool b) -> Right (VBool (a == b))
  SSeq _v1 v2 -> Right v2
  _ -> Left (ErrTypeError "Scheme: invalid operand types in primitive operation")

-- | Run a fuel-bounded Call-by-Value Scheme evaluation using 'KontStack' and 'SoAStore'.
--
-- Returns the terminal integer or boolean result (or 'SchemeError' on fuel exhaustion).
evalScheme :: Int -> SchemeTerm -> Either SchemeError (Either Bool Int32)
evalScheme !initialFuel rootTerm = runST $ do
  store <- newSoAStore
  kont  <- newKontStack
  let emptyEnv = SchemeEnv (smallArrayFromList [])
  evalLoop store kont initialFuel rootTerm emptyEnv
  where
    -- Phase 1: Downward syntax traversal (Eval)
    evalLoop
      :: SoAStore s
      -> KontStack s
      -> Int
      -> SchemeTerm
      -> SchemeEnv
      -> ST s (Either SchemeError (Either Bool Int32))
    evalLoop !store !kont !fuel (In node) !env
      | fuel <= 0 = pure (Left ErrOutOfFuel)
      | otherwise = case node of
          -- 1. Variable lookup from SoAStore
          SVar ix -> case lookupSchemeEnv env ix of
            Nothing   -> pure (Left (ErrUnboundVar ix))
            Just addr -> do
              val <- readSchemeVal store addr
              applyLoop store kont (fuel - 1) val

          -- 2. Lambda abstraction produces a closure immediately
          SLam arity body ->
            applyLoop store kont (fuel - 1) (VClosure arity body env)

          -- 3. Let binding: evaluate rhs, then bind in body (desugared as 1-arg app)
          SLet rhs body -> do
            pushFrameSoA kont FT_SchemeAppFn 0 0
              (unsafeCoerce# (VClosure 1 body env))
              (unsafeCoerce# ([] :: [SchemeTerm], [] :: [SchemeVal s], env))
            evalLoop store kont (fuel - 1) rhs env

          -- 4. Lexical mutation (set! ix rhs)
          SSet ix rhs -> case lookupSchemeEnv env ix of
            Nothing -> pure (Left (ErrUnboundVar ix))
            Just addr -> do
              pushFrameSoA kont FT_SchemeSet addr 0
                (unsafeCoerce# ()) (unsafeCoerce# ())
              evalLoop store kont (fuel - 1) rhs env

          -- 5. Short-circuiting conditional (if cond thenBranch elseBranch)
          SIf condT thenT elseT -> do
            pushFrameSoA kont FT_SchemeIf 0 0
              (unsafeCoerce# (thenT, elseT))
              (unsafeCoerce# env)
            evalLoop store kont (fuel - 1) condT env

          -- 6. First-class continuation capture (call/cc receiver)
          SCallCC receiverTerm -> do
            pushFrameSoA kont FT_SchemeCallCC 0 0
              (unsafeCoerce# env) (unsafeCoerce# ())
            evalLoop store kont (fuel - 1) receiverTerm env

          -- 7. Multi-argument function or continuation application
          SApp fnTerm argTerms -> do
            pushFrameSoA kont FT_SchemeAppArgs 0 0
              (unsafeCoerce# argTerms)
              (unsafeCoerce# env)
            evalLoop store kont (fuel - 1) fnTerm env

          -- 8. All other pure syntax nodes: delegate to Generic1 McBride Dissection!
          _ -> case stepIn node of
            Left valNode -> case reducePureScheme valNode of
              Left err  -> pure (Left err)
              Right val -> applyLoop store kont (fuel - 1) val
            Right (firstChild, dissected) -> do
              pushFrameSoA kont FT_PureDissect 0 0
                (unsafeCoerce# dissected)
                (unsafeCoerce# env)
              evalLoop store kont (fuel - 1) firstChild env

    -- Phase 2: Upward continuation application (Apply)
    applyLoop
      :: SoAStore s
      -> KontStack s
      -> Int
      -> SchemeVal s
      -> ST s (Either SchemeError (Either Bool Int32))
    applyLoop !store !kont !fuel !val
      | fuel <= 0 = pure (Left ErrOutOfFuel)
      | otherwise = do
          mbFrame <- popFrameSoA kont
          case mbFrame of
            Nothing -> case val of
              VInt n  -> pure (Right (Right n))
              VBool b -> pure (Right (Left b))
              _       -> pure (Left (ErrTypeError "Scheme: non-primitive root result"))

            Just (ft, intA, _intB, ptrA, ptrB)
              -- Generic McBride Dissection frame: plug Clown 'val' and step to next Joker!
              | ft == FT_PureDissect -> do
                  let !dis = unsafeCoerce# ptrA :: Dissect SchemeF (SchemeVal s) SchemeTerm
                      !env = unsafeCoerce# ptrB :: SchemeEnv
                  case stepNext val dis of
                    Left completedNode -> case reducePureScheme completedNode of
                      Left err   -> pure (Left err)
                      Right val' -> applyLoop store kont (fuel - 1) val'
                    Right (nextTerm, dis') -> do
                      pushFrameSoA kont FT_PureDissect 0 0
                        (unsafeCoerce# dis')
                        (unsafeCoerce# env)
                      evalLoop store kont (fuel - 1) nextTerm env

              -- Conditional branch selection
              | ft == FT_SchemeIf -> do
                  let (!thenT, !elseT) = unsafeCoerce# ptrA :: (SchemeTerm, SchemeTerm)
                      !env             = unsafeCoerce# ptrB :: SchemeEnv
                  case val of
                    VBool False -> evalLoop store kont (fuel - 1) elseT env
                    _           -> evalLoop store kont (fuel - 1) thenT env

              -- In-place SoAStore variable mutation (set!)
              | ft == FT_SchemeSet -> do
                  writeSchemeVal store intA val
                  applyLoop store kont (fuel - 1) VUnit

              -- call/cc: capture O(1) CoW KontStack and invoke receiver closure
              | ft == FT_SchemeCallCC -> do
                  captured <- captureKontSoA kont
                  invokeTarget store kont (fuel - 1) val [VCont captured]

              -- Function evaluated; now evaluate argument spine left-to-right
              | ft == FT_SchemeAppArgs -> do
                  let !argTerms = unsafeCoerce# ptrA :: [SchemeTerm]
                      !env      = unsafeCoerce# ptrB :: SchemeEnv
                  case argTerms of
                    [] -> invokeTarget store kont (fuel - 1) val []
                    (a0 : rest) -> do
                      pushFrameSoA kont FT_SchemeAppFn 0 0
                        (unsafeCoerce# val)
                        (unsafeCoerce# (rest, [] :: [SchemeVal s], env))
                      evalLoop store kont (fuel - 1) a0 env

              -- Evaluating argument list spine
              | ft == FT_SchemeAppFn -> do
                  let !fnVal = unsafeCoerce# ptrA :: SchemeVal s
                      (!remArgs, !accVals, !env) =
                        unsafeCoerce# ptrB :: ([SchemeTerm], [SchemeVal s], SchemeEnv)
                      !accVals' = val : accVals
                  case remArgs of
                    [] -> invokeTarget store kont (fuel - 1) fnVal (reverse accVals')
                    (nextArg : moreArgs) -> do
                      pushFrameSoA kont FT_SchemeAppFn 0 0
                        (unsafeCoerce# fnVal)
                        (unsafeCoerce# (moreArgs, accVals', env))
                      evalLoop store kont (fuel - 1) nextArg env

              | otherwise ->
                  pure (Left (ErrTypeError "Scheme: unknown continuation frame tag"))

    -- Invoke either a lexical closure or a first-class captured continuation:
    invokeTarget
      :: SoAStore s
      -> KontStack s
      -> Int
      -> SchemeVal s
      -> [SchemeVal s]
      -> ST s (Either SchemeError (Either Bool Int32))
    invokeTarget !store !kont !fuel !target !args = case target of
      VClosure arity body cEnv
        | length args /= arity ->
            pure (Left (ErrArityMismatch arity (length args)))
        | otherwise -> do
            argAddrs <- mapM (allocSchemeVal store) args
            evalLoop store kont (fuel - 1) body (extendSchemeEnv argAddrs cEnv)

      VCont captured -> case args of
        [retVal] -> do
          -- O(1) restoration of the captured 32-frame SoA KontStack!
          restoreKontSoA kont captured
          applyLoop store kont (fuel - 1) retVal
        _ -> pure (Left (ErrArityMismatch 1 (length args)))

      _ -> pure (Left (ErrTypeError "Scheme: attempt to call non-procedure"))

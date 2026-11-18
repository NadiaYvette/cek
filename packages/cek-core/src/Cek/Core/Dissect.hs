{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Cek.Core.Dissect
-- Description : McBride Clowns-and-Jokers polynomial functor dissection for CEK frames.
--
-- Automatically derives small-step continuation frames for any syntax functor
-- with a 'Generic1' instance, separating evaluated values (Clowns, left of the hole)
-- from unevaluated terms (Jokers, right of the hole).
--
-- === Theoretical Foundation: Functor Dissection
--
-- Conor McBride's classic functional pearl /"Clowns to the left of me, Jokers to the right"/
-- (POPL 2008) showed that the continuation frames of small-step abstract machines (such as
-- the CEK, SECD, and Krivine machines) are precisely the /dissections/ of syntax functors.
--
-- For any polynomial functor \(F(X)\), its dissection is a bifunctor \(F'(C, J)\) where:
--
--   * \(C\) represents /Clowns/: values in subterms to the left of the active evaluation hole
--     that have already been evaluated to weak-head or full normal forms.
--   * \(J\) represents /Jokers/: terms in subterms to the right of the active evaluation hole
--     that remain unevaluated in their initial syntactic state.
--
-- By instantiating dissection generically over GHC's 'Generic1' representation, any AST
-- functor equipped with 'DeriveGeneric1' automatically inherits correct, type-safe
-- small-step evaluation context frames without manual AST-traversal boilerplate.
--
-- === Machine Strategy Taxonomy
--
-- To support diverse evaluation semantics across the language spectrum (e.g. Scheme's
-- strict Call-by-Value, Dhall's Strong Call-by-Need, and Mercury's backtracking search),
-- the abstract machine is parameterized along three orthogonal axes:
--
--   1. 'BindPolicy': How variable bindings are captured and evaluated.
--   2. 'NormDepth': How deeply subterms are evaluated (WHNF vs full normal form).
--   3. 'ControlMode': How continuations and branching are managed.
module Cek.Core.Dissect
  ( -- * Dissection Type Classes
    Dissectable(..)
  , GDissect(..)
  , GenericDissect(..)

    -- * Dissection Representation Bifunctors
  , Void2
  , Unit2(..)
  , Sum2(..)
  , Prod2(..)
  , ListDissect(..)

    -- * Abstract Machine Classification Axes
  , BindPolicy(..)
  , NormDepth(..)
  , ControlMode(..)
  , MachineProfile(..)
  ) where

import Data.Bifunctor (Bifunctor(..))
import Data.Kind (Type)
import GHC.Generics
  ( Generic1(..)
  , K1(..)
  , M1(..)
  , Par1(..)
  , Rec1(..)
  , U1(..)
  , (:*:)(..)
  , (:+:)(..)
  )

-- | Axis 1: Variable binding evaluation strategy.
--
-- Determines when and how sub-expressions assigned to variables are evaluated:
data BindPolicy
  = BindCBV
    -- ^ Strict Call-by-Value: arguments are evaluated to values before function application
    -- (e.g. standard Scheme, ML, OCaml, and Strict Haskell).
  | BindCBN
    -- ^ Pure Call-by-Name: arguments are passed unevaluated as closures and re-evaluated
    -- on every variable reference (e.g. Algol 60, pure lambda-calculus).
  | BindNeed
    -- ^ Strong Call-by-Need / Lazy: arguments are passed as shared thunks and evaluated
    -- at most once on first reference, updating the cell in-place (e.g. Haskell, Dhall).
  deriving (Eq, Ord, Show)

-- | Axis 2: Normalization depth.
--
-- Determines whether reduction stops at top-level constructors or proceeds recursively:
data NormDepth
  = DepthWHNF
    -- ^ Weak-Head Normal Form: evaluation stops at the outermost constructor, lambda,
    -- or primitive literal. Subterms under lambdas or constructor arguments are not forced.
  | DepthNF
    -- ^ Full Normal Form: evaluation reduces terms completely under binders and constructors.
    -- Essential for type-level languages, proof assistants, and Dhall's semantic hashing.
  deriving (Eq, Ord, Show)

-- | Axis 3: Continuation and state-space branching discipline.
--
-- Governs the execution topology and multi-shot continuation capabilities:
data ControlMode
  = DetOneShot
    -- ^ Deterministic single-shot execution: the continuation stack is strictly linear
    -- and discarded upon return or unhandled exception.
  | MultiShotCtl
    -- ^ First-class multi-shot continuations: allows capturing continuations as values
    -- (e.g. Scheme's @call/cc@, delimited control operators @shift@/@reset@).
  | NondetAAM
    -- ^ Abstract Accounting Machine / Relational Search: continuation frames branch
    -- across choice-points, supporting backtracking (e.g. Prolog, Mercury, Kanren).
  deriving (Eq, Ord, Show)

-- | Compile-time profile specializing the CEK/CESK abstract machine.
--
-- Encapsulates the complete behavioral profile of an interpreter engine.
data MachineProfile = Profile
  { profBind    :: !BindPolicy
    -- ^ The binding evaluation strategy for variables and arguments.
  , profDepth   :: !NormDepth
    -- ^ The target normalization depth for expressions.
  , profControl :: !ControlMode
    -- ^ The control-flow and continuation capture capability.
  }
  deriving (Eq, Ord, Show)

-- | Class of syntax functors admitting small-step left-to-right dissection.
--
-- Any syntax functor @f@ that can be dissected yields an associated bifunctor
-- @Dissect f c j@ representing the one-hole evaluation context where:
--
--   * @c@ is the type of evaluated Clowns (values to the left of the hole).
--   * @j@ is the type of unevaluated Jokers (terms to the right of the hole).
class (Functor f, Bifunctor (Dissect f)) => Dissectable f where
  -- | Associated dissection bifunctor representing continuation frames.
  type Dissect f :: Type -> Type -> Type
  type Dissect f = GenericDissect (Rep1 f)

  -- | Enter the leftmost child hole of a syntax node.
  --
  -- Returns 'Left' with the node intact if it contains no child holes (i.e. is a leaf value),
  -- or 'Right' with the first child term @j@ paired with the continuation frame.
  stepIn :: f j -> Either (f c) (j, Dissect f c j)
  default stepIn
    :: (Generic1 f, GDissect (Rep1 f), Dissect f ~ GenericDissect (Rep1 f))
    => f j -> Either (f c) (j, Dissect f c j)
  stepIn fj = case gStepIn (from1 fj) of
    Left fc        -> Left (to1 fc)
    Right (j, dis) -> Right (j, GenericDissect dis)

  -- | Plug an evaluated value 'c' into the active hole and advance to the next hole.
  --
  -- If all child holes have been filled with evaluated values, returns 'Left' with the
  -- completed node. Otherwise, returns 'Right' with the next unevaluated child term @j@
  -- and the updated continuation frame.
  stepNext :: c -> Dissect f c j -> Either (f c) (j, Dissect f c j)
  default stepNext
    :: (Generic1 f, GDissect (Rep1 f), Dissect f ~ GenericDissect (Rep1 f))
    => c -> Dissect f c j -> Either (f c) (j, Dissect f c j)
  stepNext c (GenericDissect dis) = case gStepNext c dis of
    Left fc         -> Left (to1 fc)
    Right (j, dis') -> Right (j, GenericDissect dis')

-- | Wrapper providing a 'Bifunctor' instance for 'Generic1'-derived dissections.
newtype GenericDissect (rep :: Type -> Type) c j =
  GenericDissect (GDissectRep rep c j)

instance Bifunctor (GDissectRep rep) => Functor (GenericDissect rep c) where
  fmap g (GenericDissect d) = GenericDissect (second g d)

instance Bifunctor (GDissectRep rep) => Bifunctor (GenericDissect rep) where
  bimap f g (GenericDissect d) = GenericDissect (bimap f g d)

-- | Generic dissection algebra over GHC's 'Rep1' representation types.
--
-- Defines inductive rules for computing the derivative of sums, products, and constants.
class Bifunctor (GDissectRep rep) => GDissect (rep :: Type -> Type) where
  -- | Representation of the one-hole context for this structural representation.
  type GDissectRep rep :: Type -> Type -> Type

  -- | Step into the leftmost subterm of this representation.
  gStepIn   :: rep j -> Either (rep c) (j, GDissectRep rep c j)

  -- | Supply a value to the current hole and step to the next subterm.
  gStepNext :: c -> GDissectRep rep c j -> Either (rep c) (j, GDissectRep rep c j)

-- | Empty dissection bifunctor for nullary constructors and constant fields.
data Void2 c j deriving (Functor)

instance Bifunctor Void2 where
  bimap _ _ v = case v of {}

-- | Dissection of 'U1' (empty constructor without fields).
--
-- Since there are no fields, stepping in immediately returns 'Left U1'.
instance GDissect U1 where
  type GDissectRep U1 = Void2
  gStepIn U1    = Left U1
  gStepNext _ v = case v of {}

-- | Dissection of 'K1' (constant data field not parameterized by the recursive term).
--
-- Constant fields (such as variable names, primitive integers, strings) cannot be stepped into.
instance GDissect (K1 i a) where
  type GDissectRep (K1 i a) = Void2
  gStepIn (K1 a) = Left (K1 a)
  gStepNext _ v  = case v of {}

-- | Singleton dissection frame for a single recursive child term.
data Unit2 c j = Unit2 deriving (Eq, Show, Functor)

instance Bifunctor Unit2 where
  bimap _ _ Unit2 = Unit2

-- | Dissection of 'Par1' (the recursive parameter hole).
--
-- Stepping in immediately finds the single hole, yielding 'Unit2'.
instance GDissect Par1 where
  type GDissectRep Par1 = Unit2
  gStepIn (Par1 j)  = Right (j, Unit2)
  gStepNext c Unit2 = Left (Par1 c)

-- | Dissection through container functor 'Rec1 f'.
--
-- Delegates dissection directly to the inner 'Dissectable' container functor @f@.
instance Dissectable f => GDissect (Rec1 f) where
  type GDissectRep (Rec1 f) = Dissect f
  gStepIn (Rec1 fj) = case stepIn fj of
    Left fc       -> Left (Rec1 fc)
    Right (j, df) -> Right (j, df)
  gStepNext c df = case stepNext c df of
    Left fc        -> Left (Rec1 fc)
    Right (j, df') -> Right (j, df')

-- | Dissection through metadata wrappers 'M1'.
--
-- Passes through directly to the underlying representation.
instance GDissect f => GDissect (M1 i meta f) where
  type GDissectRep (M1 i meta f) = GDissectRep f
  gStepIn (M1 fj) = case gStepIn fj of
    Left fc       -> Left (M1 fc)
    Right (j, df) -> Right (j, df)
  gStepNext c df = case gStepNext c df of
    Left fc        -> Left (M1 fc)
    Right (j, df') -> Right (j, df')

-- | Sum dissection: disjoint union of two alternative continuation frames.
data Sum2 d1 d2 c j = InL2 !(d1 c j) | InR2 !(d2 c j)
  deriving (Eq, Show)

instance (Bifunctor d1, Bifunctor d2) => Functor (Sum2 d1 d2 c) where
  fmap g (InL2 x) = InL2 (second g x)
  fmap g (InR2 y) = InR2 (second g y)

instance (Bifunctor d1, Bifunctor d2) => Bifunctor (Sum2 d1 d2) where
  bimap f g (InL2 x) = InL2 (bimap f g x)
  bimap f g (InR2 y) = InR2 (bimap f g y)

-- | Dissection of constructor sum 'f :+: g'.
--
-- Distributes over sum alternatives: evaluates within the chosen constructor branch.
instance (GDissect f, GDissect g) => GDissect (f :+: g) where
  type GDissectRep (f :+: g) = Sum2 (GDissectRep f) (GDissectRep g)
  gStepIn (L1 fj) = case gStepIn fj of
    Left fc       -> Left (L1 fc)
    Right (j, df) -> Right (j, InL2 df)
  gStepIn (R1 gj) = case gStepIn gj of
    Left gc       -> Left (R1 gc)
    Right (j, dg) -> Right (j, InR2 dg)
  gStepNext c (InL2 df) = case gStepNext c df of
    Left fc        -> Left (L1 fc)
    Right (j, df') -> Right (j, InL2 df')
  gStepNext c (InR2 dg) = case gStepNext c dg of
    Left gc        -> Left (R1 gc)
    Right (j, dg') -> Right (j, InR2 dg')

-- | Leibniz product dissection:
--
-- By the product rule \(\partial(F \times G) = (\partial F \times G) + (F \times \partial G)\),
-- evaluation proceeds in two phases:
--
--   1. 'StepL': stepping inside the left factor @df@ while the right factor @g j@ waits as a Joker.
--   2. 'StepR': the left factor @f c@ is fully evaluated to Clowns, and stepping proceeds in @dg@.
data Prod2 f g df dg c j
  = StepL !(df c j) !(g j)
    -- ^ The left factor is currently being stepped into; right factor is unevaluated.
  | StepR !(f c)    !(dg c j)
    -- ^ The left factor is complete (all Clowns); the right factor is being stepped into.

instance (Functor g, Bifunctor df, Bifunctor dg)
      => Functor (Prod2 f g df dg c) where
  fmap g (StepL df gj) = StepL (second g df) (fmap g gj)
  fmap g (StepR fc dg) = StepR fc            (second g dg)

instance (Functor f, Functor g, Bifunctor df, Bifunctor dg)
      => Bifunctor (Prod2 f g df dg) where
  bimap f g (StepL df gj) = StepL (bimap f g df) (fmap g gj)
  bimap f g (StepR fc dg) = StepR (fmap f fc)    (bimap f g dg)

-- | Dissection of pair product 'f :*: g'.
--
-- Implements standard left-to-right applicative order evaluation across pairs of fields.
instance (Functor f, Functor g, GDissect f, GDissect g) => GDissect (f :*: g) where
  type GDissectRep (f :*: g) = Prod2 f g (GDissectRep f) (GDissectRep g)
  gStepIn (fj :*: gj) = case gStepIn fj of
    Right (j, df) -> Right (j, StepL df gj)
    Left fc       -> case gStepIn gj of
      Right (j, dg) -> Right (j, StepR fc dg)
      Left gc       -> Left (fc :*: gc)
  gStepNext c (StepL df gj) = case gStepNext c df of
    Right (j, df') -> Right (j, StepL df' gj)
    Left fc        -> case gStepIn gj of
      Right (j, dg) -> Right (j, StepR fc dg)
      Left gc       -> Left (fc :*: gc)
  gStepNext c (StepR fc dg) = case gStepNext c dg of
    Right (j, dg') -> Right (j, StepR fc dg')
    Left gc        -> Left (fc :*: gc)

-- | Dissection of a variable-arity list '[r]' into reversed Clowns and remaining Jokers.
--
-- Accumulates evaluated elements in reverse order for O(1) consing, reversing on completion.
data ListDissect c j = ListDissect ![c] ![j]
  deriving (Eq, Show)

instance Functor (ListDissect c) where
  fmap g (ListDissect cs js) = ListDissect cs (map g js)

instance Bifunctor ListDissect where
  bimap f g (ListDissect cs js) = ListDissect (map f cs) (map g js)

-- | Dissectable instance for standard lists '[]'.
--
-- Traverses elements from head to tail, evaluating each element in sequence.
instance Dissectable [] where
  type Dissect [] = ListDissect
  stepIn []       = Left []
  stepIn (j : js) = Right (j, ListDissect [] js)
  stepNext c (ListDissect cs [])       = Left (reverse (c : cs))
  stepNext c (ListDissect cs (j : js)) = Right (j, ListDissect (c : cs) js)

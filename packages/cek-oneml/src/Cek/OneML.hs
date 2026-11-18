{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# OPTIONS_GHC -Wno-pattern-namespace-specifier #-}

-- |
-- Module      : Cek.Examples.OneML
-- Description : Rossberg 1ML first-class module evaluator with MergeMorph3 existential sealing.
--
-- Models 1ML structures and signatures as flat 'SchemaId'-indexed arrays of lazy
-- 'SoAStore' addresses, using 'MergeMorph3' for module @include@ ('OpPreferR')
-- and existential sealing @Mod :> Sig@ ('OpRestrict').
--
-- === Background: Rossberg's 1ML
--
-- Andreas Rossberg's /"1ML — Core and the Modules in the Same Language"/ (ICFP 2015)
-- showed that the traditional stratified distinction between ML core expressions
-- and ML modules (structures, signatures, functors) can be completely dissolved.
-- Modules become first-class records, functors become ordinary functions, and
-- signatures become first-class record types with existential components.
--
-- === Efficient Interpretation with MergeMorph3
--
-- Traditional implementations of 1ML require heavy elaborators that translate
-- module constructs into System \(F_\omega\) terms with dynamic dictionary passing.
-- This CEK machine implementation executes 1ML directly on flat unboxed structures:
--
--   1. Structures and signatures are flat arrays of lazy cells indexed by 'FieldId'
--      and mapped to structural 'SchemaId' identifiers in 'Pykinos.Schema.HiddenClass'.
--   2. Module extension (@include M@) compiles into a single $O(N_1 + N_2)$ linear
--      merge plan ('OpPreferR') via 'synthesizeMergeMorph3'.
--   3. Existential sealing (@Mod :> Sig@) computes a domain restriction ('OpRestrict')
--      in $O(|Sig|)$ time. For every abstract type field ('SpecAbstract'), the evaluator
--      mints a fresh, globally unique skolem constant ('CT_WNeu') in 'SoAStore',
--      hiding the concrete implementation without dynamic wrapper closures.
--
-- > **Demonstrative Reference Implementation**: This package is an educational
-- > and demonstrative reference implementation showcasing Andreas Rossberg's 1ML
-- > first-class module system over the CEK abstract machine with MergeMorph3
-- > existential sealing and Pykinos hidden classes. It is provided primarily as an
-- > executable architectural example within the @cek@ ecosystem documentation.
--
module Cek.OneML
  ( -- * Type Specifications
    TypeSpec(..)

    -- * 1ML Syntax
  , OneMLTerm(..)

    -- * Values and Weak-Head Normal Forms
  , OneMLWHNF(..)

    -- * Continuation Frame Tags
  , pattern FT_1ML_App
  , pattern FT_1ML_Proj
  , pattern FT_1ML_IncludeL
  , pattern FT_1ML_IncludeR
  , pattern FT_1ML_SealSig
  , pattern FT_1ML_SealMod

    -- * Sealing and Evaluation
  , stepOneMLSealing
  , evalOneML
  ) where

import Control.Monad (when)
import Control.Monad.ST (ST, runST)
import Data.Bits (shiftR, (.&.))
import Data.Int (Int32)
import Data.Primitive.ByteArray
  ( MutableByteArray
  , newByteArray
  , readByteArray
  , writeByteArray
  )
import Data.Primitive.PrimArray
  ( PrimArray
  , indexPrimArray
  , sizeofPrimArray
  )
import Data.Primitive.SmallArray
  ( SmallArray
  , indexSmallArray
  , readSmallArray
  , sizeofSmallArray
  , smallArrayFromList
  , writeSmallArray
  )
import Data.Word (Word32)
import GHC.Exts (unsafeCoerce#)

import Cek.Pykinos.Kont
  ( FrameTag(..)
  , KontStack
  , newKontStack
  , pattern FT_UpdateWHNF
  , popFrameSoA
  , pushFrameSoA
  )
import Cek.Pykinos.Store
  ( CellTag(..)
  , SoAStore(..)
  , StoreChunk(..)
  , acquireSlot
  , allocThunkSoA
  , allocWLitSoA
  , allocWNeuSoA
  , newSoAStore
  , pattern CT_Thunk
  , pattern CT_WBinder
  , pattern CT_WLit
  , pattern CT_WNeu
  , pattern CT_WRecord
  , readCellPhaseSoA
  , unCellTag
  )
import Pykinos.Schema.HiddenClass
  ( FieldId(..)
  , MergeMorph3(..)
  , RecordOp(..)
  , SchemaId(..)
  , decodeMergeCode3
  , findFieldSlot
  , synthesizeMergeMorph3
  )

-- | Frame tag for evaluating a functor argument cell.
pattern FT_1ML_App      :: FrameTag
pattern FT_1ML_App      = FrameTag 30

-- | Frame tag for projecting a field from an evaluated module structure.
pattern FT_1ML_Proj     :: FrameTag
pattern FT_1ML_Proj     = FrameTag 31

-- | Frame tag for evaluating the left-hand module in an @include@ (@//@) expression.
pattern FT_1ML_IncludeL :: FrameTag
pattern FT_1ML_IncludeL = FrameTag 32

-- | Frame tag for evaluating the right-hand module in an @include@ (@//@) expression.
pattern FT_1ML_IncludeR :: FrameTag
pattern FT_1ML_IncludeR = FrameTag 33

-- | Frame tag for evaluating the signature expression in existential sealing.
pattern FT_1ML_SealSig  :: FrameTag
pattern FT_1ML_SealSig  = FrameTag 34

-- | Frame tag for applying signature restriction and skolemization to the module structure.
pattern FT_1ML_SealMod  :: FrameTag
pattern FT_1ML_SealMod  = FrameTag 35

-- | Type specifications inside a 1ML signature structure.
data TypeSpec
  = SpecAbstract
    -- ^ Opaque abstract type field (@type t@): generates a fresh skolem 'CT_WNeu'.
  | SpecManifest !OneMLTerm
    -- ^ Transparent type alias (@type t = tau@): preserves the underlying type cell.
  | SpecVal      !OneMLTerm
    -- ^ Value field specification (@val x : tau@): preserves the lazy value thunk.
  deriving (Eq, Show)

-- | Unified 1ML Core and Module AST.
data OneMLTerm
  = MVar     !Int
    -- ^ Variable reference resolved via De Bruijn indexing into the environment.
  | MLit     !Int32
    -- ^ 32-bit signed integer literal value.
  | MReified !TypeSpec
    -- ^ Reified first-class type specification treated as a value.
  | MFunctor !OneMLTerm !OneMLTerm
    -- ^ First-class functor / function abstraction taking a domain signature and body.
  | MApp     !OneMLTerm !OneMLTerm
    -- ^ Application of a functor to a module argument.
  | MLet     !OneMLTerm !OneMLTerm
    -- ^ Lexical let binding introducing a local module or value definition.
  | MStruct  !SchemaId !(SmallArray OneMLTerm)
    -- ^ First-class module structure pairing an interned 'SchemaId' with component terms.
  | MProj    !OneMLTerm !FieldId
    -- ^ Structure projection @M.x@ retrieving the field labeled by 'FieldId'.
  | MInclude !OneMLTerm !OneMLTerm
    -- ^ Asymmetric module inclusion / union @include M1 in M2@ using 'OpPreferR'.
  | MSeal    !OneMLTerm !OneMLTerm
    -- ^ Existential signature sealing @M :> S@ using 'OpRestrict' and skolem generation.
  deriving (Eq, Show)

-- | Weak-Head Normal Form representation for 1ML values and modules.
data OneMLWHNF
  = V1Lit          !Int32
    -- ^ Unboxed integer literal value.
  | V1Spec         !TypeSpec ![Int32]
    -- ^ Evaluated type specification closure.
  | V1Functor      !Int32 !OneMLTerm ![Int32]
    -- ^ Evaluated functor closure capturing parameter domain address, body, and env.
  | V1Struct       !SchemaId !(SmallArray Int32)
    -- ^ Evaluated structure pairing a 'SchemaId' with an array of lazy store addresses.
  | V1AbstractType !Int32
    -- ^ Opaque existential skolem type constant generated during signature sealing.
  deriving (Eq, Show)

-- | Execute 1ML existential sealing (@Mod :> Sig@) in O(|Sig|) using 'MergeMorph3'
--   with 'OpRestrict'. Private fields omitted from 'Sig' are never forced, while
--   'SpecAbstract' fields mint fresh skolem symbols in 'SoAStore'.
stepOneMLSealing
  :: SoAStore s
  -> MutableByteArray s
  -> MergeMorph3
  -> SchemaId
  -> SmallArray Int32
  -> SmallArray Int32
  -> ST s OneMLWHNF
stepOneMLSealing store symCounter (MergeMorph3 !restrictPlan) !sigSchema !modAddrs !sigAddrs = do
  let !nOut = sizeofPrimArray restrictPlan
  sealedAddrs <- mapM (\i -> do
    let !code = indexPrimArray restrictPlan i
        !modSlot = case decodeMergeCode3 code of
          Left (Left idx1) -> idx1
          _                -> error "OneML: invalid OpRestrict code"
        !modAddr = indexSmallArray modAddrs modSlot
        !sigAddr = indexSmallArray sigAddrs i
    (!sigTag, !_aux, !sigChk, !sigSlot) <- readCellPhaseSoA store sigAddr
    if sigTag == CT_WBinder
      then do
        spec :: TypeSpec <- unsafeCoerce# <$> readSmallArray (scPtrA sigChk) sigSlot
        case spec of
          SpecAbstract -> do
            sym :: Int32 <- readByteArray symCounter 0
            writeByteArray symCounter 0 (sym + 1)
            allocWNeuSoA store sym
          SpecManifest _ -> pure modAddr
          SpecVal _      -> pure modAddr
      else pure modAddr
    ) [0 .. nOut - 1]
  pure (V1Struct sigSchema (smallArrayFromList sealedAddrs))

-- | Store a computed 'OneMLWHNF' into an existing 'SoAStore' cell address.
writeOneMLWHNF :: SoAStore s -> Int32 -> OneMLWHNF -> ST s ()
writeOneMLWHNF SoAStore{..} !addr !whnf = do
  let !ix   = fromIntegral addr :: Int
      !slot = ix .&. 0xFFF
  StoreChunk{..} <- readSmallArray ssChunks (ix `shiftR` 12)
  case whnf of
    V1Lit n -> do
      writeByteArray scUnboxed slot (unCellTag CT_WLit)
      writeByteArray scUnboxed (5120 + slot) n
    V1AbstractType sym -> do
      writeByteArray scUnboxed slot (unCellTag CT_WNeu)
      writeByteArray scUnboxed (5120 + slot) sym
    V1Spec spec env -> do
      writeByteArray scUnboxed slot (unCellTag CT_WBinder)
      writeSmallArray scPtrA slot (unsafeCoerce# spec)
      writeSmallArray scPtrB slot (unsafeCoerce# env)
    V1Functor domAddr body env -> do
      writeByteArray scUnboxed slot (unCellTag CT_WBinder)
      writeByteArray scUnboxed (5120 + slot) domAddr
      writeSmallArray scPtrA slot (unsafeCoerce# body)
      writeSmallArray scPtrB slot (unsafeCoerce# env)
    V1Struct (SchemaId sid) addrs -> do
      writeByteArray scUnboxed slot (unCellTag CT_WRecord)
      writeByteArray scUnboxed (5120 + slot) (fromIntegral sid :: Int32)
      writeSmallArray scPtrA slot (unsafeCoerce# addrs)

-- | Evaluate a closed 1ML expression given a schema lookup table mapping
--   'SchemaId' to its sorted 'PrimArray Word32' field descriptor.
evalOneML
  :: (SchemaId -> PrimArray Word32)
  -> (PrimArray Word32 -> SchemaId)
  -> OneMLTerm
  -> OneMLWHNF
evalOneML lookupSchema internSchema rootTerm = runST $ do
  store      <- newSoAStore
  kont       <- newKontStack
  symCounter <- newByteArray 4
  writeByteArray symCounter 0 (0 :: Int32)

  let evalTerm !term !env = case term of
        MVar ix -> evalAddr (env !! ix)
        MLit n  -> applyWHNF (V1Lit n)
        MReified spec -> applyWHNF (V1Spec spec env)
        MFunctor dom body -> do
          domAddr <- allocThunkSoA store dom env
          applyWHNF (V1Functor domAddr body env)
        MLet e1 e2 -> do
          a1 <- allocThunkSoA store e1 env
          evalTerm e2 (a1 : env)
        MApp fn arg -> do
          argAddr <- allocThunkSoA store arg env
          pushFrameSoA kont FT_1ML_App argAddr 0 (unsafeCoerce# ()) (unsafeCoerce# ())
          evalTerm fn env
        MStruct sid terms -> do
          let !n = sizeofSmallArray terms
          addrs <- mapM (\i -> allocThunkSoA store (indexSmallArray terms i) env) [0 .. n - 1]
          applyWHNF (V1Struct sid (smallArrayFromList addrs))
        MProj modT (FieldId fid) -> do
          pushFrameSoA kont FT_1ML_Proj (fromIntegral fid) 0 (unsafeCoerce# ()) (unsafeCoerce# ())
          evalTerm modT env
        MInclude m1 m2 -> do
          a1 <- allocThunkSoA store m1 env
          pushFrameSoA kont FT_1ML_IncludeL a1 0 (unsafeCoerce# ()) (unsafeCoerce# ())
          evalTerm m2 env
        MSeal modT sigT -> do
          modAddr <- allocThunkSoA store modT env
          pushFrameSoA kont FT_1ML_SealSig modAddr 0 (unsafeCoerce# ()) (unsafeCoerce# ())
          evalTerm sigT env

      evalAddr !addr = do
        (!tag, !aux, !chk, !slot) <- readCellPhaseSoA store addr
        case tag of
          CT_Thunk -> do
            t   :: OneMLTerm <- unsafeCoerce# <$> readSmallArray (scPtrA chk) slot
            env :: [Int32]   <- unsafeCoerce# <$> readSmallArray (scPtrB chk) slot
            pushFrameSoA kont FT_UpdateWHNF addr 0 (unsafeCoerce# ()) (unsafeCoerce# ())
            evalTerm t env
          CT_WLit -> applyWHNF (V1Lit aux)
          CT_WNeu -> applyWHNF (V1AbstractType aux)
          CT_WRecord -> do
            addrs :: SmallArray Int32 <- unsafeCoerce# <$> readSmallArray (scPtrA chk) slot
            applyWHNF (V1Struct (SchemaId (fromIntegral aux)) addrs)
          CT_WBinder -> do
            pA <- readSmallArray (scPtrA chk) slot
            pB <- readSmallArray (scPtrB chk) slot
            if aux == 0
              then applyWHNF (V1Spec (unsafeCoerce# pA) (unsafeCoerce# pB))
              else applyWHNF (V1Functor aux (unsafeCoerce# pA) (unsafeCoerce# pB))
          _ -> error "OneML: invalid cell phase"

      applyWHNF !whnf = do
        mbFrame <- popFrameSoA kont
        case mbFrame of
          Nothing -> pure whnf
          Just (ft, intA, _intB, ptrA, _ptrB)
            | ft == FT_UpdateWHNF -> do
                writeOneMLWHNF store intA whnf
                applyWHNF whnf
            | ft == FT_1ML_App -> case whnf of
                V1Functor _dom body env ->
                  evalTerm body (intA : env)
                _ -> error "OneML: non-functor in MApp"
            | ft == FT_1ML_Proj -> case whnf of
                V1Struct sid addrs ->
                  let !fids = lookupSchema sid
                      !fid  = FieldId (fromIntegral intA)
                  in case findFieldSlot fids fid of
                       Just slotIx -> evalAddr (indexSmallArray addrs slotIx)
                       Nothing     -> error "OneML: missing field in MProj"
                _ -> error "OneML: non-struct in MProj"
            | ft == FT_1ML_IncludeL -> do
                pushFrameSoA kont FT_1ML_IncludeR 0 0 (unsafeCoerce# whnf) (unsafeCoerce# ())
                evalAddr intA
            | ft == FT_1ML_IncludeR -> do
                let !rhsWHNF = unsafeCoerce# ptrA :: OneMLWHNF
                case (whnf, rhsWHNF) of
                  (V1Struct sid1 addrs1, V1Struct sid2 addrs2) -> do
                    let (!fOut, MergeMorph3 !plan) =
                          synthesizeMergeMorph3 OpPreferR (lookupSchema sid1) (lookupSchema sid2)
                        !sidOut = internSchema fOut
                        !nOut   = sizeofPrimArray plan
                        !outArr = smallArrayFromList
                          [ case decodeMergeCode3 (indexPrimArray plan i) of
                              Left (Left idx1)  -> indexSmallArray addrs1 idx1
                              Left (Right idx2) -> indexSmallArray addrs2 idx2
                              _                 -> error "OneML: impossible collision in OpPreferR"
                          | i <- [0 .. nOut - 1]
                          ]
                    applyWHNF (V1Struct sidOut outArr)
                  _ -> error "OneML: non-struct in MInclude"
            | ft == FT_1ML_SealSig -> case whnf of
                V1Struct (SchemaId sigSid) sigAddrs -> do
                  -- Evaluate the signature's TypeSpec cells to WHNF so stepOneMLSealing can inspect them:
                  let forceSpecs !i
                        | i >= sizeofSmallArray sigAddrs = pure ()
                        | otherwise = do
                            let !sAddr = indexSmallArray sigAddrs i
                            (!sTag, _, !sChk, !sSlot) <- readCellPhaseSoA store sAddr
                            when (sTag == CT_Thunk) $ do
                              sTerm :: OneMLTerm <- unsafeCoerce# <$> readSmallArray (scPtrA sChk) sSlot
                              sEnv  :: [Int32]   <- unsafeCoerce# <$> readSmallArray (scPtrB sChk) sSlot
                              case sTerm of
                                MReified sp -> writeOneMLWHNF store sAddr (V1Spec sp sEnv)
                                _           -> pure ()
                            forceSpecs (i + 1)
                  forceSpecs 0
                  pushFrameSoA kont FT_1ML_SealMod (fromIntegral sigSid) 0
                    (unsafeCoerce# sigAddrs) (unsafeCoerce# ())
                  evalAddr intA
                _ -> error "OneML: non-signature struct in MSeal"
            | ft == FT_1ML_SealMod -> case whnf of
                V1Struct modSchema modAddrs -> do
                  let !sigSchema = SchemaId (fromIntegral intA)
                      !sigAddrs  = unsafeCoerce# ptrA :: SmallArray Int32
                      (!_fOut, !restrictMorph) =
                        synthesizeMergeMorph3 OpRestrict (lookupSchema modSchema) (lookupSchema sigSchema)
                  sealed <- stepOneMLSealing store symCounter restrictMorph sigSchema modAddrs sigAddrs
                  applyWHNF sealed
                _ -> error "OneML: non-module struct in MSeal"
            | otherwise -> error "OneML: unknown continuation frame"

  evalTerm rootTerm []

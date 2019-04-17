module NVT.Encoders.InstEncoder where

import NVT.Bits
import NVT.Loc
import NVT.Diagnostic
import NVT.IR
import NVT.Encoders.Codable

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Data.Bits
import Data.Int
import Data.List
import Data.Word
import Debug.Trace
import Text.Printf
import qualified Control.Monad.State as CMS
import qualified Control.Monad.Trans.Except as CME
import Data.Functor.Identity

runInstEncoders :: [Inst] -> Either Diagnostic ([Word128],[Diagnostic])
runInstEncoders is = do
  (ws,dss) <- unzip <$> sequence (map runInstEncoder is)
  return (ws,concat dss)

runInstEncoder :: Inst -> Either Diagnostic (Word128,[Diagnostic])
runInstEncoder i = runE (iLoc i) (eInst i)
runInstDbgEncoder :: Inst -> Either Diagnostic (Word128,[Diagnostic],[(Field,Word64)])
runInstDbgEncoder i = runDbgE (iLoc i) (eInst i)

-------------------------------------------------------------------------------

data ESt =
  ESt {
    esLoc :: !Loc
  , esInst :: !Word128
  , esMask :: !Word128
  , esFields :: ![(Field,Word64)]
  , esWarnings :: ![Diagnostic]
  } deriving Show


mkESt :: Loc -> ESt
mkESt loc = ESt loc (Word128 0 0) (Word128 0 0) [] []

type E = CMS.StateT ESt (CME.Except Diagnostic)


runE :: Loc -> E () -> Either Diagnostic (Word128,[Diagnostic])
runE loc encode =  (\(x,y,_) -> (x,y)) <$> runDbgE loc encode
runDbgE :: Loc -> E () -> Either Diagnostic (Word128,[Diagnostic],[(Field,Word64)])
runDbgE loc encode =
  case CME.runExcept (CMS.runStateT encode (mkESt loc)) of
    Left d_err -> Left d_err{dLoc = loc} -- exception
    Right (_,es) ->
      Right (
          esInst es
        , reverse (esWarnings es)
        , sortOn (fOffset . fst) (esFields es)
        )

-- eFatal :: (MonadTrans t, Monad m) => Diagnostic -> t (CME.ExceptT Diagnostic m) a
eFatal :: String -> E a
eFatal msg = do
  loc <- CMS.gets esLoc
  lift (CME.throwE (Diagnostic loc msg)) -- we patch in the location later
eFatalF :: Field -> String -> E a
eFatalF f msg = eFatal (fName f ++ ": " ++ msg)

eWarning :: String -> E ()
eWarning msg = CMS.modify $
  \es -> es{esWarnings = Diagnostic (esLoc es) msg:esWarnings es}

eField :: Field -> Word64 -> E ()
eField f val = do
  es <- CMS.get
  let mask
        | fLength f == 64 = 0xFFFFFFFFFFFFFFFF
        | otherwise = (1`shiftL`fLength f) - 1
  unless (val <= mask) $
    eFatal $ "field value overflows " ++ fName f
  let mask_val = getField128 (fOffset f) (fLength f) (esMask es)
  when ((mask_val .&. mask) /= 0) $
    eFatal $ "field overlaps another field already set" -- TODO: find it
  let new_mask = putField128 (fOffset f) (fLength f) mask (esMask es)
  let new_inst = putField128 (fOffset f) (fLength f) val  (esInst es)
  CMS.modify $ \es -> es{esInst = new_inst, esMask = new_mask, esFields = (f,val):esFields es}


eTrace :: String -> E ()
eTrace s = trace s $ return ()

eFieldE :: Field -> Either String Word64 -> E ()
eFieldE f e =
  case e of
    Left err -> eFatal (fName f ++ ": " ++ err)
    Right val -> eField f val

eEncode :: Codeable e => Field -> e -> E ()
eEncode f = eFieldE f . encode

eFieldU32 :: Field -> Word64 -> E ()
eFieldU32 = eFieldUnsignedImm 32
eFieldUnsignedImm :: Int -> Field -> Word64 -> E ()
eFieldUnsignedImm bits f val
  | val <= 2^bits - 1 = eField f val
  | otherwise = eFatalF f "value out of bounds"
eFieldS32 :: Field -> Int64 -> E ()
eFieldS32 = eFieldSignedImm 32
eFieldSignedImm :: Int -> Field -> Int64 -> E ()
eFieldSignedImm bits f val
  | val >= -2^(bits-1) && val < 2^(bits-1) = eField f (field_mask .&. w_val)
--  | high_bits /= 0 && high_bits /= 0xFFFFFFFF00000000 = eField f (field_mask .&. w_val)
  | otherwise = eFatalF f "value out of bounds"
  where w_val = fromIntegral val :: Word64
        field_mask
          | fLength f == 64 = 0xFFFFFFFFFFFFFFFF
          | otherwise = (1`shiftL`fLength f) - 1

        high_mask = complement field_mask
        high_bits = high_mask .&. w_val

-------------------------------------------------------------------------------


eInst :: Inst -> E ()
eInst i = enc
  where op = iOp i

        enc = do
          case oMnemonic op of
            "MOV" -> eMOV
            "S2R" -> eS2R
            "IADD3" -> eIADD3
            s -> eFatal $ "unsupported operation"
          eDepInfo (iDepInfo i)

        ePredication :: E ()
        ePredication =
          case iPredication i of
            PredNONE -> ePredicationAt fPREDICATION False PT
            PredP sign pr -> ePredicationAt fPREDICATION sign pr
            PredUP sign pr -> ePredicationAt fPREDICATION sign pr

        ePredicationAt :: Codeable p => Field -> Bool -> p -> E ()
        ePredicationAt f sign pr =
          case encode pr of
            Left e -> eFatalF f "INTERNAL ERROR: invalid predicate register"
            Right reg_bits -> eField f (sign_bit .|. reg_bits)
              where sign_bit = if sign then 0x8 else 0x0

        eDepInfo :: DepInfo -> E ()
        eDepInfo di = do
          eEncode fDEPINFO_STALLS (diStalls di)
          eEncode fDEPINFO_YIELD (not (diYield di)) -- yield is inverted
          let eBarAlloc f mb =
                case mb of
                  Nothing -> eField f 7 -- 0x7 means alloc none
                  Just bi
                    | bi <= 0 || bi > 7 -> eFatalF f "invalid barrier index"
                    | otherwise -> eField f (fromIntegral (bi - 1))
          eBarAlloc fDEPINFO_WRBAR (diAllocWr di)
          eBarAlloc fDEPINFO_RDBAR (diAllocRd di)
          eEncode fDEPINFO_WMASK (diWaitSet di)

        eDstRegR :: E ()
        eDstRegR =
          case iDsts i of
            [DstR r] -> eEncode fDST_REG r
            [_] -> eFatal "wrong kind of destination operand"
            _ -> eFatal "wrong number of destination operands"

        ensureNoNegAbs :: Bool -> Bool -> E ()
        ensureNoNegAbs neg abs = do
          when neg $
            eFatal "unary instructions don't support src negation modifier"
          when abs $
            eFatal "unary instructions don't support src aboslute-value modifier"

        eConstOffDiv4 :: Field -> Int -> E ()
        eConstOffDiv4 f soff = do
          when ((soff`mod`4)/=0) $
            eFatalF f "constant offset must be a multiple of 4"
          eField fSRCCOFF (fromIntegral soff `div` 4)

        -- 1 = R, 4 = IMM, 5 = const
        eUnrSrcs :: [Src] -> E ()
        eUnrSrcs srcs =
          case srcs of
            [SrcR neg abs reu reg] -> do
              eField fREGFILE 1
              eEncode fSRC1_REG reg -- src goes in [39:32]
              ensureNoNegAbs neg abs
              eEncode fSRC1_REUSE reu -- use Src1.Reuse
            [SrcC neg abs six soff] -> do
              eField fREGFILE 5
              eField fSRCCIX  (fromIntegral six)
              eConstOffDiv4 fSRCCOFF soff
              ensureNoNegAbs neg abs
            [SrcI imm] -> do
              eField fREGFILE 4
              eFieldU32 fSRCIMM imm
            [SrcUR neg ur] -> do
              eEncode fSRC1_UREG ur
              eEncode fSRC1_NEG neg
              eField fREGFILE 6
              eEncode fUNIFORMREG True
            [_] -> eFatal "wrong kind of source operand"
            _ -> eFatal "wrong number of source operands"

        ----------------------------------------------
        eMOV :: E ()
        eMOV = do
          eField fOPCODE 0x002
          ePredication
          eDstRegR
          case iSrcs i of
            [src,SrcI imm] -> do
              eUnrSrcs [src]
              eField fMOV_SRC2_IMM4 (fromIntegral imm)
            srcs -> do
              -- MOV without the imm encodes as 0xF
              eUnrSrcs srcs
              eField fMOV_SRC2_IMM4 0xF
          return ()

        eS2R :: E ()
        eS2R = do
          eField fOPCODE 0x119
          ePredication
          eDstRegR
          eField fREGFILE 0x4
          case iSrcs i of
            [SrcSR sr] ->
              eEncode fS2R_SRC0 sr
            _ -> eFatal "S2R requires SR* register source"

        eIADD3 :: E ()
        eIADD3 = do
          eField fOPCODE 0x010
          ePredication
          eDstRegR
          eEncode fIADD3_X (iHasInstOpt InstOptX i)
          -- the first two operands may be predicate sources,
          -- if they are omitted, we encode PT (0x7); neither has a sign
          (p0,p1,srcs) <-
                case iSrcs i of
                  (SrcP p0neg p0:SrcP p1neg p1:sfx)
                    | p0neg -> eFatal "predicate negation not support on extra predicate source (0)"
                    | p1neg -> eFatal "predicate negation not support on extra predicate source (1)"
                    | otherwise -> return (p0,p1,sfx)
                  (SrcP p0neg p0:sfx)
                    | p0neg -> eFatal "predicate negation not support on extra predicate source (0)"
                    | otherwise -> return (p0,PT,sfx)
                  sfx -> return (PT,PT,sfx)
          eEncode fIADD3_SRCPRED0 p0
          eEncode fIADD3_SRCPRED1 p1
          let encodeSrcR :: Int -> (Field,Maybe Field,Field,Field) -> Src -> E ()
              encodeSrcR ix (fNEG,mfABS,fREU,fREG) (SrcR neg abs reu r) = do
                eEncode fNEG neg
                case mfABS of
                  Nothing
                    | abs -> eFatal $ "absolute value not supported on Src"++show ix++" for this instruction type"
                    | otherwise -> return () -- no abs supported, but they didn't ask for it
                  Just fABS -> eEncode fABS abs
                eEncode fREU reu
                eEncode fREG r
          let encodeSrc0R :: Src -> E ()
              encodeSrc0R = encodeSrcR 0 (fSRC0_NEG,Just fSRC0_ABS,fSRC0_REUSE,fSRC0_REG)
          let encodeSrc1R :: Src -> E ()
              encodeSrc1R = encodeSrcR 1 (fSRC1_NEG,Just fSRC1_ABS,fSRC1_REUSE,fSRC1_REG)
          let encodeSrc2R :: Src -> E ()
              encodeSrc2R = encodeSrcR 1 (fSRC2_NEG,Nothing,fSRC2_REUSE,fSRC2_REG)
          case srcs of
              -- iadd3_noimm__RRR_RRR
            [s0@(SrcR _ _ _ r0),s1@(SrcR _ _ _ _),s2@(SrcR _ _ _ _)] -> do
              eField fREGFILE 0x1
              eEncode fUNIFORMREG False
              --
              encodeSrc0R s0
              encodeSrc1R s1
              encodeSrc2R s2
              eEncode fUNIFORMREG False
              -- iadd3_noimm__RCR_RCR
            [s0@(SrcR _ _ _ _),s1@(SrcC neg abs six soff),s2@(SrcR _ _ _ _)] -> do
              eField fREGFILE 0x5
              eEncode fUNIFORMREG False
              --
              encodeSrc0R s0
              --
              eEncode fSRC1_NEG neg
              eEncode fSRC1_ABS abs
              eEncode fSRC1_CIX six
              eConstOffDiv4 fSRC1_COFF soff
              --
              encodeSrc2R s2
            -- iadd3_noimm__RCxR_RCxR
            [s0@(SrcR _ _ _ _),s1@(SrcCX neg abs sur soff),s2@(SrcR _ _ _ _)] -> do
              eField fREGFILE 0x5
              eEncode fUNIFORMREG True
              --
              encodeSrc0R s0
              --
              eEncode fSRC1_NEG neg
              eEncode fSRC1_ABS abs
              eEncode fSRC1_UREG sur
              eConstOffDiv4 fSRC1_COFF soff
              --
              encodeSrc2R s2
            -- iadd3_imm__RsIR_RIR
            [s0@(SrcR _ _ _ _),s1@(SrcI imm),s2@(SrcR _ _ _ _)] -> do
              eField fREGFILE 0x4
              eEncode fUNIFORMREG False
              --
              encodeSrc0R s0
              --
              eField fSRC1_IMM imm
              --
              encodeSrc2R s2
            -- iadd3_noimm__RUR_RUR
            [s0@(SrcR _ _ _ _),s1@(SrcUR neg ur),s2@(SrcR _ _ _ _)] -> do
              eField fREGFILE 0x6
              eEncode fUNIFORMREG True
              --
              encodeSrc0R s0
              --
              eEncode fSRC1_UREG ur
              eEncode fSRC1_NEG neg
              eEncode fUNIFORMREG True
              --
              encodeSrc2R s2
            [_,_,_] -> eFatal "unsupported operand kinds to IADD3"
            _ -> eFatal "wrong number of operands to IADD3"
          -- these are the extra source predicate expressions
          -- for the .X case
          -- e.g. iadd3_x_noimm__RCR_RCR
          eField (fi "IADD.UNKNOWN76_80" 76 5) 0x1E -- probably [80:77] = 0xF !PT
          eField (fi "IADD.UNKNOWN90_87" 87 4) 0xF
          return ()

-------------------------------------------------------------------------------
data Field =
  Field {
    fName :: !String
  , fOffset :: !Int
  , fLength :: !Int
  , fFormat :: !(Word128 -> Word64 -> String)
  }
instance Show Field where
  show f =
    "Field {\n" ++
    "  fName = " ++ show (fName f) ++ "\n" ++
    "  fOffset = " ++ show (fOffset f) ++ "\n" ++
    "  fLength = " ++ show (fLength f) ++ "\n" ++
    "  fFormat = ...function...\n" ++
    "}"

f :: String -> Int -> Int -> (Word128 -> Word64 -> String) -> Field
f = Field
fi :: String -> Int -> Int -> Field
fi nm off len = f nm off len $ const show
fb :: String -> Int -> Int -> String -> Field
fb nm off len true = fl nm off len ["",true]
fl :: String -> Int -> Int -> [String] -> Field
fl nm off len vs = f nm off len fmt
  where fmt _ v
          | fromIntegral v >= length vs = show v ++ "?"
          | otherwise = vs !! fromIntegral v
fC :: (Codeable c,Syntax c) => c -> String -> Int -> Int -> Field
fC c_dummy nm off len = f nm off len fmt
  where fmt _ val =
          case decode val of
            Left err -> err
            Right c -> areSame c c_dummy $ format c

        areSame :: a -> a -> b -> b
        areSame _ _ b = b

after :: Field -> String -> Int -> (Word64 -> String) -> Field
after f nm len fmt = afterG f nm len $ const fmt
afterI :: Field -> String -> Int -> Field
afterI f nm len = after f nm len show
afterB :: Field -> String -> Int -> String -> Field
afterB f nm len meaning = afterG f nm len (\_ v -> if v /= 0 then meaning else "")
afterG :: Field -> String -> Int -> (Word128 -> Word64 -> String) -> Field
afterG fBEFORE nm len fmt = f nm (fOffset fBEFORE + fLength fBEFORE) len fmt

fReserved :: Int -> Int -> Field
fReserved off len = f rESERVED_NAME off len $ \_ v ->
  if v /= 0 then "should be zeros" else ""

rESERVED_NAME :: String
rESERVED_NAME = "*Reserved*"

fIsReserved :: Field -> Bool
fIsReserved = (==rESERVED_NAME) . fName
-------------------------------------------------------------------------------
-- field constructors for our syntax
fR :: String -> Int -> Field
fR nm off = fC (undefined :: R) nm off 8
fUR :: String -> Int -> Field
fUR nm off = fC (undefined :: UR) nm off 6

-------------------------------------------------------------------------------


fOPCODE :: Field
fOPCODE = fi "Opcode" 0 9

fREGFILE :: Field
fREGFILE = fi "RegFile" 9 3

fPREDICATION :: Field
fPREDICATION = fi "Predication" 12 4

fABS :: Int -> Int -> Field
fABS src_ix off = fb ("Src" ++ show src_ix ++ ".AbsVal") off 1 "|..|"
fNEG :: Int -> Int -> Field
fNEG src_ix off = fb ("Src" ++ show src_ix ++ ".Negated") off 1 "-(..)"

fDST_REG :: Field
fDST_REG = fR "Dst.Reg" 16
fSRC0_REG :: Field
fSRC0_REG = fR "Src0.Reg" 24
fSRC0_ABS :: Field
fSRC0_ABS = fABS 1 72
fSRC0_NEG :: Field
fSRC0_NEG = fNEG 1 73

fSRC1_REG :: Field
fSRC1_REG = fR "Src1.Reg" 32
fSRC1_UREG :: Field
fSRC1_UREG = fUR "Src1.UReg" 32
fSRC1_IMM :: Field
fSRC1_IMM = fSRCIMM{fName = "Src1.Imm"} -- more specific name
fSRC1_CIX :: Field
fSRC1_CIX = fSRCCIX{fName = "Src1.ConstIndex"}
fSRC1_COFF :: Field
fSRC1_COFF = fSRCCOFF{fName = "Src1.ConstOffset"}
fSRC1_CUIX :: Field
fSRC1_CUIX = fSRCCOFF{fName = "Src1.ConstIndex"}
fSRC1_ABS :: Field
fSRC1_ABS = fABS 1 62
fSRC1_NEG :: Field
fSRC1_NEG = fNEG 1 63
fSRC2_REG :: Field
fSRC2_REG = fR "Src0.Reg" 64
fSRC2_ABS :: Field -- (not supported for IADD), [74] is .X
fSRC2_ABS = fABS 2 74
fSRC2_NEG :: Field
fSRC2_NEG = fNEG 2 75

fSRCIMM :: Field
fSRCIMM = fi "Src.Imm" 32 32
fSRCCOFF :: Field
fSRCCOFF = f "Src.ConstOffset" 40 14 fmt
  where fmt w128 off =
            c_or_cx ++ "[..][" ++ printf "0x%X" (4*off) ++ "]"
          where c_or_cx = if testBit w128 91 then "cx" else "c"
fSRCCIX :: Field
fSRCCIX = f "Src.ConstIndex" 54 5 fmt
  where fmt w128 val = "c[" ++ show val ++ "][..]"
fSRCCUIX :: Field
fSRCCUIX = f "Src.ConstIndex" 32 6 $ \_ val ->
  let ureg = if val == 63 then "URZ" else ("UR" ++show val)
    in "cx[" ++ ureg ++ "][..]"

fUNIFORMREG :: Field
fUNIFORMREG = fb "EnableUniformReg" 91 1 "uniform registers enabled"

fDEPINFO_STALLS :: Field
fDEPINFO_STALLS = f "DepInfo.Stalls" 105 4 $ \_ val -> -- [108:105]
  if val == 0 then "" else ("!" ++ show val)

fDEPINFO_YIELD :: Field
fDEPINFO_YIELD = after fDEPINFO_STALLS "DepInfo.NoYield" 1 $ -- [109]
  \val ->
    if val == 1
      then "no yield: prefer same warp"
      else "yield: prefer another warp"
fDEPINFO_WRBAR :: Field
fDEPINFO_WRBAR = fRWBAR fDEPINFO_YIELD "DepInfo.WrBar" -- [112:110]
fDEPINFO_RDBAR :: Field
fDEPINFO_RDBAR = fRWBAR fDEPINFO_WRBAR "DepInfo.RdBar" -- [115:113]
fRWBAR :: Field -> String -> Field
fRWBAR fAFT name = after fAFT name 3 fmt
  where fmt 7 = "no barrier"
        fmt val = "+" ++ show (val+1) ++ "." ++ which
        which = take 1 $ drop 1 (dropWhile (/='.') name)

fDEPINFO_WMASK :: Field
fDEPINFO_WMASK = afterI fDEPINFO_RDBAR "DepInfo.WtMask" 6 -- [121:116]
fUNK_REUSE :: Field
fUNK_REUSE = afterB fUNK_REUSE "???.Reuse" 1 ".reuse" -- [122]
fSRC0_REUSE :: Field
fSRC0_REUSE = afterB fDEPINFO_WMASK "Src0.Reuse" 1 ".reuse" -- [123]
fSRC1_REUSE :: Field
fSRC1_REUSE = afterB fSRC0_REUSE "Src1.Reuse" 1 ".reuse" -- [124]
fSRC2_REUSE :: Field
fSRC2_REUSE = afterB fSRC1_REUSE "Src2.Reuse" 1 ".reuse" -- [125]
-- zeros [127:126]


-------------------------------------------------------------------------------
-- special per-instruction fields with unknown behavior
--
fMOV_SRC2_IMM4 :: Field
fMOV_SRC2_IMM4 = fi "Mov.Src2.Imm4" 72 4

fS2R_SRC0 :: Field
fS2R_SRC0 = fi "S2R.Src0" 72 8

fIADD3_X :: Field
fIADD3_X = fi "IADD3.X" 74 1

fIADD3_SRCPRED0 :: Field
fIADD3_SRCPRED0 = fi "IADD3.SrcPred0" 81 3
fIADD3_SRCPRED1 :: Field
fIADD3_SRCPRED1 = fi "IADD3.SrcPred1" 84 3
-- bit 4
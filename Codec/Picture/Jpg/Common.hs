{-# LANGUAGE BangPatterns #-}
module Codec.Picture.Jpg.Common
    ( decodeInt
    , dcCoefficientDecode
    , deQuantize
    , decodeRrrrSsss
    , zigZagReorderForward 
    , zigZagReorderForwardv
    , zigZagReorder
    , inverseDirectCosineTransform
    , unpackInt
    , unpackMacroBlock
    , rasterMap
    ) where

import Control.Applicative( (<$>), pure )
import Control.Monad( replicateM, when )
import Control.Monad.ST( ST, runST )
import Data.Bits( unsafeShiftL, unsafeShiftR, (.&.) )
import Data.Int( Int16, Int32 )
import Data.List( foldl' )
import Data.Maybe( fromMaybe )
import Data.Word( Word8 )
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as M
import Foreign.Storable ( Storable )

import Codec.Picture.Types
import Codec.Picture.BitWriter
import Codec.Picture.Jpg.Types
import Codec.Picture.Jpg.FastIdct
import Codec.Picture.Jpg.DefaultTable

{-# INLINE decodeInt #-}
decodeInt :: Int -> BoolReader s Int32
decodeInt ssss = do
    signBit <- getNextBitJpg
    let dataRange = 1 `unsafeShiftL` fromIntegral (ssss - 1)
        leftBitCount = ssss - 1
    -- First following bits store the sign of the coefficient, and counted in
    -- SSSS, so the bit count for the int, is ssss - 1
    if signBit
       then (\w -> dataRange + fromIntegral w) <$> unpackInt leftBitCount
       else (\w -> 1 - dataRange * 2 + fromIntegral w) <$> unpackInt leftBitCount

decodeRrrrSsss :: HuffmanPackedTree -> BoolReader s (Int, Int)
decodeRrrrSsss tree = do
    rrrrssss <- huffmanPackedDecode tree
    let rrrr = (rrrrssss `unsafeShiftR` 4) .&. 0xF
        ssss =  rrrrssss .&. 0xF
    pure (fromIntegral rrrr, fromIntegral ssss)

dcCoefficientDecode :: HuffmanPackedTree -> BoolReader s DcCoefficient
dcCoefficientDecode dcTree = do
    ssss <- huffmanPackedDecode dcTree
    if ssss == 0
       then return 0
       else fromIntegral <$> decodeInt (fromIntegral ssss)

-- | Apply a quantization matrix to a macroblock
{-# INLINE deQuantize #-}
deQuantize :: MacroBlock Int16 -> MutableMacroBlock s Int16
           -> ST s (MutableMacroBlock s Int16)
deQuantize table block = update 0
    where update 64 = return block
          update i = do
              val <- block `M.unsafeRead` i
              let finalValue = val * (table `VS.unsafeIndex` i)
              (block `M.unsafeWrite` i) finalValue
              update $ i + 1

inverseDirectCosineTransform :: MutableMacroBlock s Int16
                             -> ST s (MutableMacroBlock s Int16)
inverseDirectCosineTransform mBlock =
    fastIdct mBlock >>= mutableLevelShift

zigZagOrder :: MacroBlock Int
zigZagOrder = makeMacroBlock $ concat
    [[ 0, 1, 5, 6,14,15,27,28]
    ,[ 2, 4, 7,13,16,26,29,42]
    ,[ 3, 8,12,17,25,30,41,43]
    ,[ 9,11,18,24,31,40,44,53]
    ,[10,19,23,32,39,45,52,54]
    ,[20,22,33,38,46,51,55,60]
    ,[21,34,37,47,50,56,59,61]
    ,[35,36,48,49,57,58,62,63]
    ]

zigZagReorderForwardv :: (Storable a, Num a) => VS.Vector a -> VS.Vector a
zigZagReorderForwardv vec = runST $ do
    v <- M.new 64
    mv <- VS.thaw vec
    zigZagReorderForward v mv >>= VS.freeze

zigZagOrderForward :: MacroBlock Int
zigZagOrderForward = VS.generate 64 inv
  where inv i = fromMaybe 0 $ VS.findIndex (i ==) zigZagOrder

zigZagReorderForward :: (Storable a, Num a)
                     => MutableMacroBlock s a
                     -> MutableMacroBlock s a
                     -> ST s (MutableMacroBlock s a)
{-# SPECIALIZE INLINE zigZagReorderForward :: MutableMacroBlock s Int32
                                           -> MutableMacroBlock s Int32
                                           -> ST s (MutableMacroBlock s Int32) #-}
{-# SPECIALIZE INLINE zigZagReorderForward :: MutableMacroBlock s Int16
                                           -> MutableMacroBlock s Int16
                                           -> ST s (MutableMacroBlock s Int16) #-}
{-# SPECIALIZE INLINE zigZagReorderForward :: MutableMacroBlock s Word8
                                           -> MutableMacroBlock s Word8
                                           -> ST s (MutableMacroBlock s Word8) #-}
zigZagReorderForward zigzaged block = ordering zigZagOrderForward >> return zigzaged
  where ordering !table = reorder (0 :: Int)
          where reorder !i | i >= 64 = return ()
                reorder i  = do
                     let idx = table `VS.unsafeIndex` i
                     v <- block `M.unsafeRead` idx
                     (zigzaged `M.unsafeWrite` i) v
                     reorder (i + 1)

zigZagReorder :: MutableMacroBlock s Int16 -> MutableMacroBlock s Int16
              -> ST s (MutableMacroBlock s Int16)
zigZagReorder zigzaged block = do
    let update i =  do
            let idx = zigZagOrder `VS.unsafeIndex` i
            v <- block `M.unsafeRead` idx
            (zigzaged `M.unsafeWrite` i) v

        reorder 63 = update 63
        reorder i  = update i >> reorder (i + 1)

    reorder (0 :: Int)
    return zigzaged

-- | Unpack an int of the given size encoded from MSB to LSB.
unpackInt :: Int -> BoolReader s Int32
unpackInt bitCount = packInt <$> replicateM bitCount getNextBitJpg


{-# INLINE rasterMap #-}
rasterMap :: (Monad m)
          => Int -> Int -> (Int -> Int -> m ())
          -> m ()
rasterMap width height f = liner 0
  where liner y | y >= height = return ()
        liner y = columner 0
          where columner x | x >= width = liner (y + 1)
                columner x = f x y >> columner (x + 1)

packInt :: [Bool] -> Int32
packInt = foldl' bitStep 0
    where bitStep acc True = (acc `unsafeShiftL` 1) + 1
          bitStep acc False = acc `unsafeShiftL` 1

pixelClamp :: Int16 -> Word8
pixelClamp n = fromIntegral . min 255 $ max 0 n

-- | Given a size coefficient (how much a pixel span horizontally
-- and vertically), the position of the macroblock, return a list
-- of indices and value to be stored in an array (like the final
-- image)
unpackMacroBlock :: Int    -- ^ Component count
                 -> Int    -- ^ Component index
                 -> Int -- ^ Width coefficient
                 -> Int -- ^ Height coefficient
                 -> Int -- ^ x
                 -> Int -- ^ y
                 -> MutableImage s PixelYCbCr8
                 -> MutableMacroBlock s Int16
                 -> ST s ()
unpackMacroBlock compCount compIdx  wCoeff hCoeff x y
                 (MutableImage { mutableImageWidth = imgWidth,
                                 mutableImageHeight = imgHeight, mutableImageData = img })
                 block = -- trace (printf "w:%d h:%d x:%d y:%d wCoeff:%d hCoeff:%d" imgWidth imgHeight x y wCoeff hCoeff) $
                            blockVert 0
  where blockVert j | j >= dctBlockSize = return ()
        blockVert j = blockHoriz 0
          where yBase = (y * dctBlockSize + j) * hCoeff
                blockHoriz i | i >= dctBlockSize = blockVert $ j + 1
                blockHoriz i = (pixelClamp <$> (block `M.unsafeRead` (i + j * dctBlockSize))) >>= horizDup 0
                  where xBase = (x * dctBlockSize + i) * wCoeff
                        horizDup wDup _ | wDup >= wCoeff = blockHoriz $ i + 1
                        horizDup wDup compVal = vertDup 0
                          where vertDup hDup | hDup >= hCoeff = horizDup (wDup + 1) compVal
                                vertDup hDup = do
                                  let xPos = xBase + wDup
                                      yPos = yBase + hDup

                                  when (xPos < imgWidth && yPos < imgHeight)
                                       (do let mutableIdx = (xPos + yPos * imgWidth) * compCount + compIdx
                                           (img `M.unsafeWrite` mutableIdx) compVal)

                                  vertDup $ hDup + 1

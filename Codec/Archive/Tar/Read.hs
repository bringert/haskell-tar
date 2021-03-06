module Codec.Archive.Tar.Read (readTarArchive) where

import Codec.Archive.Tar.Types
import Codec.Archive.Tar.Util

import Data.Binary.Get

import Data.Char (chr,ord)
import Data.Int (Int64)
import Control.Monad (liftM)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as L
import Data.Int (Int8)
import Numeric (readOct)

-- | Reads a TAR archive from a lazy ByteString.
readTarArchive :: L.ByteString -> TarArchive
readTarArchive = runGet getTarArchive

getTarArchive :: Get TarArchive
getTarArchive = liftM TarArchive $ unfoldM getTarEntry

-- | Returns 'Nothing' if the entry is an end block.
getTarEntry :: Get (Maybe TarEntry)
getTarEntry =
    do mhdr <- getTarHeader
       case mhdr of
         Nothing -> return Nothing
         Just hdr -> do let size = contentSize hdr
                        cnt <- if size == 0 
                                then return L.empty
                                else let padding = (512 - size) `mod` 512
                                in liftM (L.take size) $ getLazyByteString $ size + padding
                        return $ Just $ TarEntry hdr cnt

-- | Get the size of the content for the given header. This can sometimes
-- be different from 'tarFileSize'. I have seen hints that some platforms
-- may set the size to non-zero values for directories.
contentSize :: TarHeader -> Int64
contentSize hdr = if hasContent hdr then tarFileSize hdr else 0

hasContent :: TarHeader -> Bool
hasContent hdr = case tarFileType hdr of
                    TarNormalFile -> True
                    TarOther _    -> True
                    _             -> False

getTarHeader :: Get (Maybe TarHeader)
getTarHeader =
    do -- FIXME: warn and return nothing on EOF
       block <- liftM B.copy $ getBytes 512
       return $ 
        if B.head block == '\NUL'
          then Nothing
          else let (hdr,chkSum) = 
                       runGet getHeaderAndChkSum $ L.fromChunks [block]
                in if checkChkSum block chkSum
                     then Just hdr
                     else error $ "TAR header checksum failure." 

checkChkSum :: B.ByteString -> Int -> Bool
checkChkSum block s = s == chkSum block' || s == signedChkSum block'
  where 
    block' = B.concat [B.take 148 block, B.replicate 8 ' ', B.drop 156 block]
    -- tar.info says that Sun tar is buggy and 
    -- calculates the checksum using signed chars
    chkSum = B.foldl' (\x y -> x + ord y) 0
    signedChkSum = B.foldl' (\x y -> x + (ordSigned y)) 0

ordSigned :: Char -> Int
ordSigned c = fromIntegral (fromIntegral (ord c) :: Int8)

getHeaderAndChkSum :: Get (TarHeader, Int)
getHeaderAndChkSum =
    do fileSuffix <- getString  100
       mode       <- getOct       8
       uid        <- getOct       8
       gid        <- getOct       8
       size       <- getOct      12
       time       <- getOct      12
       chkSum     <- getOct       8
       typ        <- getTarFileType
       target     <- getString  100
       _ustar     <- skip         6
       _version   <- skip         2
       uname      <- getString   32
       gname      <- getString   32
       major      <- getOct       8
       minor      <- getOct       8
       filePrefix <- getString  155
       _          <- skip        12      
       let hdr = TarHeader {
                            tarFileName    = filePrefix ++ fileSuffix,
                            tarFileMode    = mode,
                            tarOwnerID     = uid,
                            tarGroupID     = gid,
                            tarFileSize    = size,
                            tarModTime     = fromInteger time,
                            tarFileType    = typ,
                            tarLinkTarget  = target,
                            tarOwnerName   = uname,
                            tarGroupName   = gname,
                            tarDeviceMajor = major,
                            tarDeviceMinor = minor
                           }
       return (hdr,chkSum)

getTarFileType :: Get TarFileType
getTarFileType = 
    do c <- getChar8
       return $ case c of
                  '\0'-> TarNormalFile
                  '0' -> TarNormalFile
                  '1' -> TarHardLink
                  '2' -> TarSymbolicLink
                  '3' -> TarCharacterDevice
                  '4' -> TarBlockDevice
                  '5' -> TarDirectory
                  '6' -> TarFIFO
                  _   -> TarOther c

-- * TAR format primitive input

getOct :: Integral a => Int -> Get a
getOct n = getBytes n >>= parseOct . takeWhile (/='\0') . B.unpack
  where parseOct "" = return 0
        parseOct s = case readOct s of
                       [(x,_)] -> return x
                       _       -> fail $ "Number format error: " ++ show s

getString :: Int -> Get String
getString n = liftM (takeWhile (/='\NUL') . B.unpack) $ getBytes n

getChar8 :: Get Char
getChar8 = fmap (chr . fromIntegral) getWord8

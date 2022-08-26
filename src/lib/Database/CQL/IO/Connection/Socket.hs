-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

-- | A thin wrapper of the Network.Socket API.
module Database.CQL.IO.Connection.Socket (
    Socket,
    resolve,
    open,
    send,
    recv,
    close,
    shutdown,
    -- Re-exports
    HostName,
    PortNumber,
    ShutdownCmd (..),
) where

import Control.Applicative
import Control.Monad
import Control.Monad.Catch
import Data.ByteString (ByteString)
import Data.ByteString.Builder
import Data.Maybe (isJust)
import Data.Monoid
import Database.CQL.IO.Cluster.Host
import Database.CQL.IO.Exception (ConnectionError (..))
import Database.CQL.IO.Timeouts (Milliseconds (..))
import Network.Socket (AddrInfo (..), AddrInfoFlag (..), Family (..), HostName, PortNumber, ShutdownCmd (..), SockAddr (..))
import Network.Socket.ByteString.Lazy (sendAll)
import OpenSSL.Session (SSL, SSLContext)
import System.Timeout
import Prelude

import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Lazy as Lazy
import qualified Network.Socket as S
import qualified Network.Socket.ByteString as NB
import qualified OpenSSL.Session as SSL

data Socket = Stream !S.Socket | Tls !S.Socket !SSL

instance Show Socket where
    show (Stream s) = show s
    show (Tls s _) = show s

resolve :: HostName -> PortNumber -> IO [InetAddr]
resolve h p = do
    ais <- S.getAddrInfo (Just hints) (Just h) (Just (show p))
    return $ map (InetAddr . addrAddress) ais
  where
    hints = S.defaultHints {addrFlags = [AI_ADDRCONFIG], addrSocketType = S.Stream}

open :: Milliseconds -> InetAddr -> Maybe SSLContext -> IO Socket
open to a ctx = do
    bracketOnError (mkSock a) S.close $ \s -> do
        ok <- timeout (ms to * 1000) (S.connect s (sockAddr a))
        unless (isJust ok) $
            throwM (ConnectTimeout a)
        case ctx of
            Nothing -> return (Stream s)
            Just set -> do
                c <- SSL.connection set s
                SSL.connect c
                return (Tls s c)

mkSock :: InetAddr -> IO S.Socket
mkSock (InetAddr a) = S.socket (familyOf a) S.Stream S.defaultProtocol
  where
    familyOf (SockAddrInet _ _) = AF_INET
    familyOf (SockAddrInet6 _ _ _ _) = AF_INET6
    familyOf (SockAddrUnix _) = AF_UNIX
#if MIN_VERSION_network(2,6,1) && !MIN_VERSION_network(3,0,0)
    familyOf (SockAddrCan _) = AF_CAN
#endif

close :: Socket -> IO ()
close (Stream s) = S.close s
close (Tls s c) = SSL.shutdown c SSL.Unidirectional >> S.close s

shutdown :: Socket -> ShutdownCmd -> IO ()
shutdown (Stream s) cmd = S.shutdown s cmd
shutdown _ _ = return ()

recv :: Int -> InetAddr -> Socket -> Int -> IO Lazy.ByteString
recv x a (Stream s) n = receive x a (NB.recv s) n
recv x a (Tls _ c) n = receive x a (SSL.read c) n

receive :: Int -> InetAddr -> (Int -> IO ByteString) -> Int -> IO Lazy.ByteString
receive _ _ _ 0 = return Lazy.empty
receive x i f n = toLazyByteString <$> go n mempty
  where
    go !k !bb = do
        a <- f (k `min` x)
        when (Bytes.null a) $ throwM (ConnectionClosed i)
        let b = bb <> byteString a
        let m = k - Bytes.length a
        if m > 0 then go m b else return b

send :: Socket -> Lazy.ByteString -> IO ()
send (Stream s) b = sendAll s b
send (Tls _ c) b = mapM_ (SSL.write c) (Lazy.toChunks b)

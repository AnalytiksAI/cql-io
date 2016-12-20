-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE OverloadedStrings #-}

module Database.CQL.IO.Protocol where

import Control.Exception (throw)
import Data.ByteString.Lazy (ByteString)
import Data.Maybe (maybe)
import Data.Monoid ((<>))
import Database.CQL.Protocol
import Database.CQL.IO.Types

import qualified Data.Text.Lazy as LT

parse :: (Tuple a, Tuple b) => Compression -> (Header, ByteString) -> Response k a b
parse x (h, a) =
    case unpack x h a of
        Left  e -> throw $ InternalError ("response body reading: " ++ e)
        Right r -> r

serialise :: Tuple a => Version -> Compression -> Request k a b -> Int -> ByteString
serialise v f r i =
    let c = case getOpCode r of
                OcStartup -> noCompression
                OcOptions -> noCompression
                _         -> f
        s = mkStreamId i
    in either (throw $ InternalError "request creation") id (pack v c (tracing r) s r)
  where
    tracing :: Request k a b -> Bool
    tracing (RqQuery(Query _ p)) = maybe False id $ enableTracing p
    tracing (RqExecute(Execute _ p)) = maybe False id $ enableTracing p
    tracing _ = False

quoted :: LT.Text -> LT.Text
quoted s = "\"" <> LT.replace "\"" "\"\"" s <> "\""

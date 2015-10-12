--
-- Copyright © 2015 Insurance Group Australia
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE RankNTypes #-}

-- | Adapter code to interface with the http-client and http-client-tls
-- packages.
--
-- With this module you can streaming the request, response, or both.
--
-- To stream the request, simply replace your 'Request' 'requestBody' with one
-- created via either 'makeChunkedRequestBody' or 'makeFixedRequestBody'. You
-- have the option of either chunked encoding or a fixed size streaming
-- request. You probably want chunked encoding if that is supported.
--
-- To stream the response, use streamHTTP and provide a continuation that
-- returns a 'Consumer'. Your function will be passed the response, which it is
-- free to ignore.
--
-- To stream the request and response, simply do both.
--
-- Below is an example of a streaming response, with a streaming request.
--
-- > {-# LANGUAGE RankNTypes #-}
-- > {-# LANGUAGE OverloadedStrings #-}
-- >
-- > module Main where
-- >
-- > import Control.Quiver.HTTP
-- > import Control.Quiver
-- > import Control.Quiver.SP
-- > import Control.Monad
-- > import Data.ByteString (ByteString)
-- > import qualified Data.ByteString.Char8 as BS
-- > main :: IO ()
-- > main = do
-- >     req <- parseUrl "http://httpbin.org/post"
-- >     let req' = req { method = "POST", requestBody = makeChunkedRequestBody input}
-- >
-- >     manager <- newManager defaultManagerSettings
-- >     streamHTTP req' manager out
-- >   where
-- >     out :: Response () -> Consumer () ByteString IO ()
-- >     out _ = loop
-- >       where
-- >         loop = do
-- >             x <- fetch ()
-- >             case x of
-- >                 Just bs -> do
-- >                     qlift $ BS.putStrLn bs
-- >                     loop
-- >                 Nothing -> return ()
-- >
-- >     input :: Producer ByteString () IO ()
-- >     input = void $ decouple ("chunk1" >:> "chunk2" >:> deliver SPComplete)

module Control.Quiver.HTTP
(
  module Network.HTTP.Client,
  module Network.HTTP.Client.TLS,

  -- * Response streaming
  streamHTTP,

  -- * Request streaming
  makeChunkedRequestBody,
  makeFixedRequestBody
) where

import           Control.Monad           (unless)
import           Control.Quiver
import           Control.Quiver.Internal
import           Data.ByteString         (ByteString)
import qualified Data.ByteString         as S
import qualified Data.ByteString.Lazy    as L
import           Data.Int                (Int64)
import           Data.IORef              (newIORef, readIORef, writeIORef)
import           Network.HTTP.Client
import           Network.HTTP.Client.TLS

-- | Make a HTTP 'Request' and stream the response.
streamHTTP
    :: Request
    -- ^ The http-client 'Request', this need not be streaming.
    -> Manager
    -- ^ The http-client 'Manager', make sure you use the tls manager if you
    -- need SSL.
    -> (Response () -> Consumer x ByteString IO a)
    -- ^ Your quiver 'Consumer' continuation. Feel free to ignore the Response.
    -> IO a
streamHTTP request manager k =
    withResponse request manager handleBody
  where
    handleBody response = do
        let br = responseBody response
        let scrubbed_resp = response { responseBody = () }
        runEffect (loop br >->> k scrubbed_resp >&> snd)

    loop br = do
        bs <- qlift (L.toStrict <$> brReadSome' br chunkSize)
        unless (S.null bs) $ do
            emit_ bs
            loop br

    -- Minimum chunk size to emit, set to some reasonable page size
    chunkSize = 4096

-- Stolen from the internals of http-client
brReadSome' :: IO ByteString -> Int -> IO L.ByteString
brReadSome' brRead' =
    loop id
  where
    loop front remainder
        | remainder <= 0 = return $ L.fromChunks $ front []
        | otherwise = do
            bs <- brRead'
            if S.null bs
                then return $ L.fromChunks $ front []
                else loop (front . (bs:)) (remainder - S.length bs)

-- | Build a 'RequestBody' by chunked transfer encoding a 'Producer'.
--
-- Each 'ByteString' produced will be sent as a seperate chunk.
makeChunkedRequestBody :: Producer ByteString () IO () -> RequestBody
makeChunkedRequestBody p = RequestBodyStreamChunkedAsync (givePopper p)

-- | Build a 'RequestBody' by sending a Content-Length header and then
-- streaming a 'Producer'.
--
-- You should probably use 'makeChunkedRequestBody' if it is supported by the
-- server.
makeFixedRequestBody :: Int64 -> Producer ByteString () IO () -> RequestBody
makeFixedRequestBody len p = RequestBodyStreamAsync len (givePopper p)

-- | http-client is weird, it wants us to make poppers and give them to it.
--
-- In summary, we take a Producer and turn it into a function which: given a
-- continuation which takes an IO action that -- when called, will produce
-- successive chunks -- returns an IO () and does some super strange things.
givePopper
    :: Producer ByteString () IO ()
    -> (IO ByteString -> IO ())
    -> IO ()
givePopper producer k = do
    ref <- newIORef producer
    k (doRead ref)
  where
    doRead ref = do
        current_producer <- readIORef ref
        x <- qnext current_producer ()
        case x of
            Left () -> do
                writeIORef ref (return ())
                return S.empty
            Right (bs, next_producer) -> do
                writeIORef ref next_producer
                return bs

    -- | This is not a part of quiver because it only behaves how you might
    -- expect if you know that p is a Producer. There doesn't seem to be a good
    -- way of encoding this invariant in the types without nasty extensions.
    qnext p b' = loop p
      where
        loop (Consume _ _ q)  = loop q
        loop (Produce b k' _) = return (Right (b, k' b'))
        loop (Deliver r)      = return (Left r)
        loop (Enclose f)      = f >>= loop

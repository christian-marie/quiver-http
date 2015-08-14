--
-- Copyright © 2015 Insurance Group Australia
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Quiver.HTTP
import Control.Quiver
import Control.Quiver.SP
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS

main :: IO ()
main = do
    req <- parseUrl "http://httpbin.org/post"
    let req' = req { method = "POST", requestBody = makeChunkedRequestBody input}

    manager <- newManager defaultManagerSettings
    streamHTTP req' manager out
  where
    out :: Response () -> Consumer () ByteString IO ()
    out _ = loop
      where
        loop = do
            x <- fetch ()
            case x of
                Just bs -> do
                    qlift $ BS.putStrLn bs
                    loop
                Nothing -> return ()

    input :: Producer ByteString () IO ()
    input = void $ decouple ("chunk1" >:> "chunk2" >:> deliver SPComplete)

{-# LANGUAGE ScopedTypeVariables #-}

module Main where
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Monad
import           Data.Hash.MD5
import qualified Data.Map               as M
import           DHT
import           Network.Socket
import           Numeric.Natural
import           Prelude                hiding (lookup)



main = do
  dht <- newDHT
  insert 123 "blah" dht
  r <- lookup 123 dht
  print r
  insert 123 "blubb" dht
  r <- lookup 123 dht
  print r
  case r of
    Just (c,v) -> do
                    b <- cas c 123 "meep" dht
                    print b
    _ -> print "123 not found"

  r <- lookup 123 dht
  print r
  delete 123 dht
  r <- lookup 123 dht
  print r

  ha <- inet_addr "127.0.0.1"

  let nodes = [ (Peer nid ha p) | i <- [1..100] , let nid = fromIntegral $ md5i $ Str $ show ((31000 + (10*i))::Natural) , let p = fromIntegral $ 7000 + i ]

  instances::[(Instance Integer Int)] <- mapM createInstance nodes

  mapM_ (\i -> do
          joinNetwork i (head nodes)
        ) $ tail instances

{-
  mapM (\i -> do
    let anode = nodes !! i

    putStrLn $ "Searching for node " ++ show (_id anode)
    nl <- iterativeFindNode (instances !! 30) (_id anode)
    putStrLn $ "Result: \n " ++ show nl) [50..100]

  threadDelay $ 5 * 1000 * 1000
-}

  let ayb = md5i $ Str $ "aLLyOURbASEaREbELONGtOuS"

  putStrLn $ "\n\n\nSearching for node closest to : " ++ show ayb

  nl <- iterativeFindNode (instances !! 3) ayb
  putStrLn $ "Result: \n " ++ show nl

  putStrLn $ "\n\n\nStoring value " ++ show ayb ++ " => 1337"

  iterativeStoreValue (instances !! 2) ayb 1337
  res <- iterativeFindValue (instances !! 4) ayb
  putStrLn $ "\n\n\nReading stored value for " ++ show ayb ++ " => 1337"
  print res

{-
  forever $ do
    mapM_ (\i -> do
      mapM_ (pingcheck i) nodes
      threadDelay $ 1  * 1000) instances
-}



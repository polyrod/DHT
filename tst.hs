{-# LANGUAGE ScopedTypeVariables #-}
module Main where
import           Control.Concurrent
import           Control.Monad
import           Data.Hash.MD5
import qualified Data.Map           as M
import           DHT
import           Network.Socket
import           Numeric.Natural
import           Prelude            hiding (lookup)



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

  mapM_ (flip joinNetwork (head nodes)) $ tail instances

{-
  (i::(Instance Integer Int)) <- createInstance (Peer 1234 ha 7001)
  (j::(Instance Integer Int)) <- createInstance (Peer 1235 ha 7002)
  (k::(Instance Integer Int)) <- createInstance (Peer 1236 ha 7003)
  (l::(Instance Integer Int)) <- createInstance (Peer 1237 ha 7004)

  joinNetwork j (Peer 1234 ha 7001)
  threadDelay $ 5 * 1000 * 1000
  joinNetwork k (Peer 1234 ha 7001)
  threadDelay $ 5 * 1000 * 1000
  joinNetwork l (Peer 1234 ha 7001)
-}

  threadDelay $ 30 * 1000 * 1000
  let anode = nodes !! 20

  nl <- iterativeFindNode (instances !! 13) (_id anode)
  putStrLn $ "Result: \n " ++ show nl

  threadDelay $ 300 * 1000 * 1000


  forever $ do
    mapM_ (\i -> do
      mapM_ (pingcheck i) nodes
      threadDelay $ 1  * 1000) instances



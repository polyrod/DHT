module DHT.Store where

import           Control.Applicative
import qualified Control.Concurrent.STM as STM
import           Control.Monad
import qualified Data.Map               as M
import           Data.Maybe
import           System.Random


import           Data.Bits
import           Data.Hash.MD5
import           Data.List
import           Data.Word

type ChkSum = Int

newtype DHT k v = DHT (STM.TMVar (M.Map k (STM.TMVar (ChkSum , v))))

newDHT :: IO (DHT k v)
newDHT = DHT <$> STM.newTMVarIO M.empty


lookup :: Ord k => k -> DHT k v -> IO (Maybe (ChkSum,v))
lookup k (DHT tmv) = do
  m <- STM.atomically $ STM.readTMVar tmv
  case M.lookup k m of
    Just etmv -> do
      (chksum,val) <- STM.atomically $ STM.readTMVar etmv
      return . Just $ (chksum,val)

    _ -> return Nothing


insert :: Ord k => k -> v -> DHT k v -> IO ()
insert k v (DHT tmv) = do
  i <- randomIO
  STM.atomically $ do
    m <- STM.takeTMVar tmv
    if M.member k m
    then do
      let etmv = fromJust $ M.lookup k m
      STM.swapTMVar etmv (i,v)
      STM.putTMVar tmv m
    else do
      nv <- STM.newTMVar (i,v)
      let m' = M.insert k nv m
      STM.putTMVar tmv m'

delete :: Ord k => k -> DHT k v -> IO ()
delete k (DHT tmv) = do
  STM.atomically $ do
    m <- STM.takeTMVar tmv
    if M.member k m
    then do
      let etmv = fromJust $ M.lookup k m
      let m' = M.delete k m
      STM.putTMVar tmv m'
    else do
      STM.putTMVar tmv m


cas :: Ord k => ChkSum -> k -> v -> DHT k v -> IO Bool
cas chksum k v (DHT tmv) = do
  i <- randomIO
  STM.atomically $ do
    m <- STM.takeTMVar tmv
    case M.lookup k m of
      Just etmv -> do
        (chksum',val) <- STM.readTMVar etmv
        res <- if chksum' == chksum
                then do
                  STM.swapTMVar etmv (i,v)
                  return True
                else return False
        STM.putTMVar tmv m
        return res

      _ -> do
        STM.putTMVar tmv m
        return False


{-
di n = index $ fromIntegral $ md5i $ Str n

myid = md5i $ Str "aLLyOURbASEaREbELONGtOuS"


go :: Integer -> M.Map Int Int -> IO (M.Map Int Int)
go n m = do
  r <- randomIO :: IO Integer
  let i = md5i $ Str $ show r
  let d = distance myid i
  let k = fst $ index $ fromIntegral d
  let m' = M.insertWith (+) k 1 m
  if n == 0
     then return m'
     else go (n-1) m'





    if M.member k m
    then do
      let (chksum,val) <- fromJust M.lookup k m
      let m' = M.insert k (i,v)


-}

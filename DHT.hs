{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
module DHT
  ( module DHT
  , module DHT.Store
  ) where

import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.Supervisor
import           Control.Exception             hiding (handle)
import           Data.Either
import           Text.Read

import qualified Control.Concurrent.STM        as STM
import           Control.Monad
import           Control.Monad.Extra
import           Control.Monad.Loops           (forkMapM, forkMapM_,
                                                iterateUntil, whileM_)
import qualified Data.Map                      as M
import           Data.Maybe
import           Data.Ord
import           Network.Socket                hiding (recvFrom, sendTo)
import           Network.Socket.ByteString
import           System.Random


import           Data.Bits
import qualified Data.ByteString.Char8         as C
import           Data.Hash.MD5
import           Data.List
import           Data.Word
import           DHT.Store


a:: Int
a = 3
k:: Int
k = 20

debug = False

--class (Show i,Read i,Eq i,Ord i,Enum i,Bits i,Random i) => IDClass i

type IPv4 = HostAddress
type Port = Word16

newtype ID i = ID i
  deriving (Show,Read,Num,Eq,Ord,Random,Bits,Enum)

type SessionID i = ID i
data SessionMode = ASEARCH | KSEARCH
  deriving Eq

data Peer i = Peer { _id::ID i, _ip::IPv4, _port::Port }
  deriving (Eq,Show,Read)

type MsgID i = ID i
data MsgType = Ping | Pong | FindClosestNodes | FindValue | Store | NodeList | Value | Ack | Error
  deriving (Show,Read)

data Msg i = Msg { _type   :: MsgType
                 , _sender :: Peer i
                 , _mid    :: MsgID i
                 , _data   :: C.ByteString
                 }
  deriving (Show,Read)

data Session i = Session   { _sessionid  :: ID i
                           , _shortlist  :: STM.TMVar [Peer i]
                           , _shortlist' :: STM.TMVar [Peer i]
                           , _visited    :: STM.TMVar [Peer i]
                           , _pending    :: STM.TMVar [Peer i]
                           , _closest    :: STM.TMVar [Peer i]
                           , _closest'   :: STM.TMVar [Peer i]
                           , _mode       :: STM.TMVar SessionMode
                           }


data Instance i v = Instance { _self      :: Peer i
                             , _kbuckets  :: STM.TMVar (M.Map (ID i) (STM.TMVar [Peer i]))
                             , _sessions  :: STM.TMVar (M.Map i (Session i))
                             , _ht        :: DHT (ID i) v
                             , _alpha     :: Int
                             , _k         :: Int
                             ,_ioLock     :: STM.TMVar ()
                             }





newSession ::(Ord i,Random i) => Instance i v -> IO (SessionID i)
newSession inst = do

  sl <- STM.newTMVarIO []
  sl' <- STM.newTMVarIO []
  v <- STM.newTMVarIO []
  p <- STM.newTMVarIO []
  c <- STM.newTMVarIO []
  c' <- STM.newTMVarIO []
  m <- STM.newTMVarIO ASEARCH

  ss <- STM.atomically $ STM.takeTMVar $ _sessions inst
  r <- iterateUntil (`M.notMember` ss) randomIO
  let s = Session (ID r) sl sl' v p c c' m
  let ss' = M.insert r s ss
  STM.atomically $ STM.putTMVar (_sessions inst) ss'

  return (ID r)


--createInstance :: (Read i , Show i) => Peer -> IO (Instance i v)
createInstance p@(Peer id ipv4 port) = do
  kbs <- STM.newTMVarIO M.empty
  ss  <- STM.newTMVarIO M.empty
  iol  <- STM.newTMVarIO ()
  dht <- newDHT

  let inst = Instance p kbs ss dht a k iol

  supSpec <- newSupervisorSpec OneForOne
  sup <- newSupervisor supSpec

  forkSupervised sup fibonacciRetryPolicy $ bracket (do
    addrinfos <- getAddrInfo
               (Just (defaultHints {addrFlags = [AI_PASSIVE]}))
               Nothing
               (Just $ show port)

    sock <- socket
          (addrFamily $ Prelude.head addrinfos)
          Datagram
          defaultProtocol

    bind sock (addrAddress $ head addrinfos)
    return sock)

    (\s -> close s)

    (\sock -> forever $ do
                          (msgbs,sa) <- recvFrom sock 1024
                          rsp <- handle sock sa msgbs inst
                          sendTo sock (C.pack $ show rsp) sa

    )

  return inst


joinNetwork :: (Show i, Read i, Ord i, Enum i, Bits i, Random i) => Instance i v -> Peer i -> IO ()
joinNetwork inst peer@(Peer (ID pid) pip pp) = do

  when (debug) $ putStrLn "joinNetwork"

  updateKbucket inst peer
  nodes <- iterativeFindNode inst $ _id $ _self inst

  refresh inst

  dumpKbuckets inst



--storeValue :: (Show i, Read i, Show v) => Instance i v -> Peer i -> ID i -> v -> IO Bool
storeValue inst dst idata vdata = do

  let msg = Msg Store (_self inst) idata (C.pack . show $ vdata)

  isJust <$>  (exchangeMsg inst dst msg)

iterativeStoreValue :: (Show i, Read i, Ord i,Enum i, Bits i, Random i, Show v) => Instance i v -> ID i -> v -> IO Bool
iterativeStoreValue inst idata vdata = do

  nl <- iterativeFindNode inst idata
  forkMapM_ (\p -> do
    storeValue inst p idata vdata ) nl

  return True

findValue :: (Show i,Read i,Show v,Read v) => Instance i v -> Peer i -> ID i -> IO (Either [Peer i] v)
findValue inst dst idata = do

  let msg = Msg FindValue (_self inst) idata (C.pack . show $ idata)

  resp <- exchangeMsg inst dst msg

  case resp of
    Just (Msg Value _ _ bsv)     -> return . Right . read . C.unpack $ bsv
    Just (Msg NodeList _ _ bsnl) -> return . Left . read . C.unpack $ bsnl
    Just (Msg _ _ _ bsnl)        -> return . Left $ []
    Nothing                      -> return . Left $ []


iterativeFindValue :: (Show i, Read i, Ord i, Enum i, Bits i, Random i, Show v, Read v) => Instance i v -> ID i -> IO (Maybe v)
iterativeFindValue inst idata = do

  nl <- iterativeFindNode inst idata
  res <- rights <$> mapM (\p -> findValue inst p idata) nl
  case null res of
    True  -> return Nothing
    False -> return . Just . head $ res




refresh :: (Show i, Read i, Ord i,Enum i, Bits i ,Random i) => Instance i v -> IO ()
refresh inst = do
  m <- STM.atomically $ STM.readTMVar $ _kbuckets inst
  let lkbi = fst $ M.findMin m
  let hkbi = fst $ M.findMax m
  forM_  ([lkbi..hkbi]) (iterativeFindNode inst <=< index2id)



pingcheck :: (Show i, Read i, Random i ) => Instance i v -> Peer i -> IO Bool
pingcheck inst dst@(Peer i ip p)  = do
  --putStrLn $ "entering Pingcheck : " ++ show dst

  sid <- randomIO

  let msg = Msg Ping (_self inst) sid (C.pack "Ping!!!")

  resp <- exchangeMsg inst dst msg
  case resp of
    Just (Msg Pong _ _ _) -> return True
    Just (Msg _ _ _ _)    -> return False
    Nothing               -> return False




findNode :: (Show i,Read i,Ord i) => Instance i v -> SessionID i -> ID i -> Peer i -> IO [Peer i]
findNode inst (ID sid) i peer@(Peer pid ip p) = do

  when (debug) $ putStrLn "findNode"

  STM.atomically $ do
      sessions <- STM.readTMVar $ _sessions inst
      let s = fromJust $ M.lookup sid sessions

      pending <- STM.takeTMVar $ _pending s
      STM.putTMVar (_pending s) $ peer:pending


  let msg = Msg FindClosestNodes (_self inst) (ID sid) (C.pack $ show i)

  resp <- exchangeMsg inst peer msg
  case resp of
         Just (Msg NodeList peer sid' nlbs) -> do
            let (nl) = read $ C.unpack nlbs
            STM.atomically $ do
                sessions <- STM.readTMVar $ _sessions inst
                let s = fromJust $ M.lookup sid sessions

                pending <- STM.takeTMVar $ _pending s
                STM.putTMVar (_pending s) $ filter ( /= peer) pending

                visited <- STM.takeTMVar $ _visited s
                STM.putTMVar (_visited s) $ peer:visited

                shortlist <- STM.takeTMVar $ _shortlist s
                STM.putTMVar (_shortlist s) $ filter ( /= peer) shortlist

            return nl

         Nothing -> do
             STM.atomically $ do
                sessions <- STM.readTMVar $ _sessions inst
                let s = fromJust $ M.lookup sid sessions

                pending <- STM.takeTMVar $ _pending s
                STM.putTMVar (_pending s) $ filter ( /= peer) pending

                shortlist <- STM.takeTMVar $ _shortlist s
                STM.putTMVar (_shortlist s) $ filter ( /= peer) shortlist

             return []

iterativeFindNode :: (Show i , Read i, Ord i, Enum i, Bits i,Random i) => Instance i v -> ID i -> IO [Peer i]
iterativeFindNode inst i'@(ID i) = do
  when (debug) $ putStrLn "iterativeFindNode"
  sid'@(ID sid) <- newSession inst
  shortlist <- closestContacts inst i'
  STM.atomically $ do
    sessions <- STM.readTMVar $ _sessions inst
    let s = fromJust $ M.lookup sid sessions
    _<- STM.takeTMVar (_shortlist s)
    STM.putTMVar (_shortlist s) $ take (_alpha inst) $ shortlist


  whileM_ (undoneSession inst sid') $ do
    when (debug) $ putStrLn "iterativeFindNode:while"
    sl <- STM.atomically $ do
        sessions <- STM.readTMVar $ _sessions inst
        let s = fromJust $ M.lookup sid sessions
        shortlist <- STM.readTMVar $ _shortlist s
        mode <- STM.readTMVar $ _mode s
        if mode == ASEARCH
           then return $ take (_alpha inst) shortlist
           else return $ take (_k inst) shortlist

    res <- (sortPeersDist i' . nub . concat . rights)
          <$> forkMapM (findNode inst sid' i') sl

    let saneres = filter (/= (_self inst)) res
    mapM_ (updateKbucket inst) saneres
    updateSession inst sid' i' saneres

  STM.atomically $ do
    sessions <- STM.takeTMVar $ _sessions inst
    let s = fromJust $ M.lookup sid sessions
    STM.putTMVar (_sessions inst) $ M.delete sid sessions
    closest <- STM.readTMVar $ _closest s
    return $ take (_k inst) $ sortPeersDist i' $ closest


undoneSession :: (Eq i,Ord i) => Instance i v -> SessionID i -> IO Bool
undoneSession inst sid'@(ID sid) = do
  when (debug) $ putStrLn "undoneSession"
  (sl,sl',clo,clo',m) <- STM.atomically $ do
    sessions <- STM.readTMVar $ _sessions inst
    let s = fromJust $ M.lookup sid sessions
    shortlist <- STM.readTMVar $ _shortlist s
    shortlist' <- STM.readTMVar $ _shortlist' s
    closest <- STM.readTMVar $ _closest s
    closest' <- STM.readTMVar $ _closest' s
    mode <- STM.readTMVar $ _mode s
    return (shortlist,shortlist',closest,closest',mode)

  if null sl || clo == clo' && m == KSEARCH
     then return False
     else
      if clo == clo' && m == ASEARCH
        then do
            STM.atomically $ do
              sessions <- STM.readTMVar $ _sessions inst
              let s = fromJust $ M.lookup sid sessions
              _ <- STM.takeTMVar $ _mode s
              STM.putTMVar (_mode s) KSEARCH
            return True
         else
            if clo /= clo' && m == KSEARCH
              then do
                  STM.atomically $ do
                    sessions <- STM.readTMVar $ _sessions inst
                    let s = fromJust $ M.lookup sid sessions
                    _ <- STM.takeTMVar $ _mode s
                    STM.putTMVar (_mode s) ASEARCH
                  return True
              else return True



updateSession :: (Ord i,Bits i) => Instance i v -> SessionID i -> ID i -> [Peer i] -> IO ()
updateSession inst sid'@(ID sid) i peers = do
  when (debug) $ putStrLn "updateSession"
  (sl,pend,vis,clo) <- STM.atomically $ do
    sessions <- STM.readTMVar $ _sessions inst
    let s = fromJust $ M.lookup sid sessions
    pending <- STM.takeTMVar $ _pending s
    visited <- STM.readTMVar $ _visited s
    shortlist <- STM.takeTMVar $ _shortlist s
    _ <- STM.takeTMVar $ _shortlist' s
    closest <- STM.takeTMVar $ _closest s
    _ <- STM.takeTMVar $ _closest' s
    return (shortlist,pending,visited,closest)


  let nsl = take (_k inst) $ sortPeersDist i $ ((sl `union` peers) \\ (vis `union` pend))
  let osl = sl
  let nclosest = take (_k inst) $ sortPeersDist i $ (vis `union` clo)
  let oclosest = clo


  STM.atomically $ do
    sessions <- STM.readTMVar $ _sessions inst
    let s = fromJust $ M.lookup sid sessions
    STM.putTMVar (_closest s) nclosest
    STM.putTMVar (_closest' s) oclosest
    STM.putTMVar (_shortlist s) nsl
    STM.putTMVar (_shortlist' s) osl
    STM.putTMVar (_pending s) []

  when (debug) $ putStrLn "updateSession:done"

--sortPeersDist :: (ID i) -> [Peer i] -> [Peer i]
sortPeersDist i =  sortBy ((comparing (distance i . _id)))

closestContacts :: (Ord i,Enum i , Bits i) => Instance i v -> ID i -> IO [Peer i]
closestContacts inst i = do
  kbm <- STM.atomically $ STM.readTMVar $ _kbuckets inst
  let myid = _id $ _self inst
  let ind = index $ distance myid i

  closest <- case M.lookupGE ind kbm of
    Just buck -> do
      ps <- STM.atomically $ STM.readTMVar $ snd buck
      return $ sortPeersDist i ps

    Nothing -> case M.lookupLT ind kbm of
        Just buck -> do
          ps <- STM.atomically $ STM.readTMVar $ snd buck
          return $ sortPeersDist i ps
        Nothing -> return []
  --putStrLn $ "Closest: " ++ show closest
  return closest

--handle :: Socket -> SockAddr -> C.ByteString -> Instance i v -> IO (Msg)
handle sock sa msgbs inst = do
  when (debug) $ putStrLn "handle"
  case (read $ C.unpack msgbs) of
    (Msg Ping sender sid dat) -> handlePing inst sender sid dat
    (Msg FindClosestNodes sender sid dat) -> handleFindClosestNodes inst sender sid dat
    (Msg FindValue sender k _ ) -> handleFindValue inst sender k
    (Msg Store sender k bsv) -> handleStore inst sender k bsv
    (Msg Ack sender sid dat) -> return $ Msg Pong (_self inst) 1234 (C.pack "blah")
    (Msg NodeList sender sid dat) -> return $ Msg Pong (_self inst) 1234 (C.pack "blah")
    (Msg Value sender sid dat) -> return $ Msg Pong (_self inst) 1234 (C.pack "blah")
    _ -> return $ Msg Error (_self inst) 1234 ( C.pack "Error" )


handleFindValue inst sender@(Peer i ip p) k = do
  when (debug) $ putStrLn "handleFindValue"
  updateKbucket inst sender

  r <- DHT.Store.lookup k (_ht inst)
  case r of
    Just (cksm,v) -> return $ Msg Value (_self inst) k (C.pack $ show v)
    Nothing       -> do
      nl <- closestContacts inst k
      return $ Msg NodeList (_self inst) k (C.pack $ show nl)


--handleStore :: Instance i v -> Peer -> Integer -> C.ByteString -> IO Msg
handleStore inst sender@(Peer i ip p) k bsv = do
  when (debug) $ putStrLn "handleStore"
  updateKbucket inst sender
  let v = read $ C.unpack bsv

  DHT.Store.insert k v (_ht inst)
  return $ Msg Ack (_self inst) k (C.pack  "Ok")


handleFindClosestNodes :: (Show i,Read i,Ord i,Enum i,Bits i,Random i) => Instance i v -> Peer i -> MsgID i -> C.ByteString -> IO (Msg i)
handleFindClosestNodes inst sender@(Peer i ip p) epid dat = do
  when (debug) $ putStrLn "handleFindClosestNodes"
  updateKbucket inst sender
  let rid = read $ C.unpack dat
  cs <- closestContacts inst rid
  return $ Msg NodeList (_self inst) epid (C.pack $ show cs)



handlePing :: (Show i,Read i,Eq i,Ord i,Enum i,Bits i,Random i) => Instance i v -> Peer i -> MsgID i -> C.ByteString -> IO (Msg i)
handlePing inst sender@(Peer i ip p) epid dat = do
  when (debug) $ putStrLn "handlePing"
  updateKbucket inst sender
  return $ Msg Pong (_self inst) epid (C.pack "Pong!!!")


dumpKbuckets :: (Show i,Read i) => Instance i v -> IO ()
dumpKbuckets inst = do
  m <- STM.atomically $ STM.readTMVar (_kbuckets inst)
  _ <- STM.atomically $ STM.takeTMVar (_ioLock inst)
  let bl = M.toList m

  when(debug) $ putStrLn $ "Node: " ++ (show $ _self inst)

  mapM_ (\(k,b) -> do
    cs <- STM.atomically $ STM.readTMVar b
    when(debug) $ putStrLn $ "Bucket " ++ show k ++ " : " ++ show cs
    ) bl

  when (debug) $ putStrLn "\n"

  STM.atomically $ STM.putTMVar (_ioLock inst) ()



updateKbucket :: (Show i,Read i,Eq i,Ord i,Enum i,Bits i,Random i) => Instance i v -> Peer i -> IO ()
updateKbucket inst sender@(Peer i ip p) = do
  when (debug) $ putStrLn "updateKbucket"
  -- Update kbucket if sender /= self
  if sender /= _self inst
    then return ()
    else putStrLn "Still there"

  let myid = _id . _self $  inst
  let ind = index $ distance myid i

  m <- STM.atomically $ STM.takeTMVar (_kbuckets inst)
  if M.member ind m
    then do
       let kbuck = fromJust $ M.lookup ind m
       peers <- STM.atomically $ STM.takeTMVar kbuck
       if elem sender peers -- sender is in kbucket
          then do
            let peers' = (filter (/= sender) peers ) ++ [sender] -- move sender to end of kbucket

            STM.atomically $ STM.putTMVar kbuck peers' -- put kbucket back
          else do
            if length peers < _k inst -- kbucket not full
               then STM.atomically $ STM.putTMVar kbuck (peers ++ [sender]) -- add sender to end of kbucket
               else do -- kbucket full
                 -- check if head responds to ping
                 r <- pingcheck inst (head peers)
                 if r
                    then STM.atomically $ STM.putTMVar kbuck peers -- do nothing put back kbuck
                    else STM.atomically $ STM.putTMVar kbuck ((tail peers) ++ [sender]) -- drop dead head + add sender to end of kbucket

       STM.atomically $ STM.putTMVar (_kbuckets inst) m
     else do
       -- create singelton kbuck with only entry is sender
       kbuck <- STM.newTMVarIO [sender]
       let m' = M.insert ind kbuck m
       STM.atomically $ STM.putTMVar (_kbuckets inst) m'


index :: (Enum i) => ID i -> ID i
index = toEnum . floor . logBase 2  . fromIntegral . fromEnum

index2id :: (Enum i) => ID i -> IO (ID i)
index2id i = do
              let base = 2 ^ (fromEnum i)
              let nbase = base * (fromEnum i)
              (ID . toEnum) <$> randomRIO (base,nbase)

distance :: (Bits i) => ID i -> ID i -> ID i
distance = xor


exchangeMsg :: (Show i,Read i,Read (Maybe (Msg i))) => Instance i v -> Peer i -> Msg i -> IO (Maybe (Msg i))
exchangeMsg inst dst@(Peer i ip p) msg = do
  when (debug) $ putStrLn "exchangeMsg"
  let (Peer myid myip myport) = _self inst

  sock <- socket
          AF_INET
          Datagram
          defaultProtocol

  bind sock (SockAddrInet aNY_PORT (myip))

  sendTo sock (C.pack $ show msg) (SockAddrInet (read $ show p) ip)

{-
  gotreply <- STM.newTVarIO Nothing
  waiting <- forkIO $ do
    (bs,sa) <- recvFrom sock 1024
    r <- case readMaybe $ C.unpack bs of
           Just (Msg{}) -> return $ Just $ read $ C.unpack bs
           Nothing      -> return Nothing

    STM.atomically $ STM.writeTVar gotreply r

  threadDelay $ 500 * 1000
  killThread waiting
  r <- STM.readTVarIO gotreply
-}

  (bs,sa) <- recvFrom sock 4096
  --putStrLn $ "exchangeMsg : " ++ (show $ C.unpack bs)
  close sock
  case (readMaybe $ C.unpack bs) of
           Just x  -> return $ Just x
           Nothing -> return Nothing


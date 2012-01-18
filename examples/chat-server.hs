import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.Channelize
import Control.Monad
import Data.Map (Map)
import Network

import qualified Data.Map as M

type Client    = (ThreadId, String -> STM ())
type ClientMap = Map String Client

main :: IO ()
main = do
    clients <- newTVarIO M.empty :: IO (TVar ClientMap)
    let broadcast message =
            readTVar clients >>= mapM_ (\(_, send) -> send message) . M.elems

        broadcastNotice message =
            broadcast $ "* " ++ message

        broadcastMessageFrom name message =
            broadcast $ "<" ++ name ++ ">: " ++ message

    sock <- listenOn $ PortNumber 1234
    putStrLn "Listening on port 1234"
    forever $ do
        (handle, host, port) <- accept sock
        putStrLn $ "Accepted connection from " ++ host ++ ":" ++ show port
        forkIO $ channelize (connectHandle $ return handle) $ \recv send -> do
            atomically $ send "What is your name?"
            name <- atomically recv
            if name == ""
                then atomically $ send "Bye, anonymous coward"
                else do
            tid <- myThreadId
            join $ atomically $ do
                m <- readTVar clients
                writeTVar clients $ M.insert name (tid, send) m
                case M.lookup name m of
                    Nothing -> do
                        broadcastNotice $ name ++ " has connected"
                        return $ return ()
                    Just (victim_tid, victim_send) -> do
                        broadcastNotice $ name ++ " has connected (kicking previous client)"
                        victim_send $ "Another client by the name of "
                                   ++ name ++ " has connected"
                        return $ killThread victim_tid
            forever $ atomically $ recv >>= broadcastMessageFrom name

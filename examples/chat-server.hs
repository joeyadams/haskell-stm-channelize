import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.Channelize
import Control.Monad
import Data.Map (Map)
import Network
import System.IO

import qualified Data.Map as M

type Message   = String
type Name      = String
type Client    = (ThreadId, Message -> STM ())
type ClientMap = TVar (Map Name Client)

sendToClient :: Client -> String -> STM ()
sendToClient (_, client_send) msg = client_send msg

broadcast :: ClientMap -> Message -> STM ()
broadcast clients msg =
    readTVar clients >>= mapM_ (flip sendToClient msg) . M.elems

broadcastNotice :: ClientMap -> Message -> STM ()
broadcastNotice clients msg =
    broadcast clients $ "* " ++ msg

broadcastMessageFrom :: ClientMap -> Name -> Message -> STM ()
broadcastMessageFrom clients name msg =
    broadcast clients $ "<" ++ name ++ ">: " ++ msg

main :: IO ()
main = do
    clients <- newTVarIO M.empty :: IO ClientMap
    sock <- listenOn $ PortNumber 1234
    putStrLn "Listening on port 1234"
    forever $ do
        (handle, host, port) <- accept sock
        putStrLn $ "Accepted connection from " ++ host ++ ":" ++ show port

        -- Swallow carriage returns sent by telnet clients
        hSetNewlineMode handle universalNewlineMode

        forkIO $ channelize (connectHandle $ return handle) $ \duplex -> do
            atomically $ send duplex "What is your name?"
            name <- atomically $ recv duplex
            if null name
                then atomically $ send duplex "Bye, anonymous coward"
                else do
            tid <- myThreadId
            join $ atomically $ do
                m <- readTVar clients
                writeTVar clients $ M.insert name (tid, send duplex) m
                case M.lookup name m of
                    Nothing -> do
                        broadcastNotice clients $ name ++ " has connected"
                        return $ return ()
                    Just (victim_tid, victim_send) -> do
                        broadcastNotice clients $
                            name ++ " has connected (kicking previous client)"
                        victim_send $ "Another client by the name of "
                                   ++ name ++ " has connected"
                        return $ killThread victim_tid
            forever $ atomically $
                recv duplex >>= broadcastMessageFrom clients name

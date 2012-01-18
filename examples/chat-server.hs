import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.Channelize
import Control.Exception hiding (handle)
import Control.Monad
import Data.Map (Map)
import Network
import System.IO

import qualified Data.Map as M

type Message   = String
type Name      = String
type ClientMap = TVar (Map Name Client)

data Client
    = Client
        { clientThreadId    :: ThreadId
        , clientSend        :: Message -> STM ()
        }

broadcast :: ClientMap -> Message -> STM ()
broadcast clients msg =
    readTVar clients >>= mapM_ (flip clientSend msg) . M.elems

broadcastNotice :: ClientMap -> Message -> STM ()
broadcastNotice clients msg =
    broadcast clients $ "* " ++ msg

broadcastMessageFrom :: ClientMap -> Name -> Message -> STM ()
broadcastMessageFrom clients name msg =
    broadcast clients $ "<" ++ name ++ ">: " ++ msg

insertClient :: ClientMap -> Name -> (Message -> STM ()) -> IO Client
insertClient clients name c_send = do
    tid <- myThreadId
    let client = Client { clientThreadId = tid
                        , clientSend     = c_send
                        }

    join $ atomically $ do
        -- Insert the client
        m <- readTVar clients
        writeTVar clients $ M.insert name client m

        -- Broadcast that the client has connected.  If another client by the
        -- same name is connected, kick it.
        case M.lookup name m of
            Nothing -> do
                broadcastNotice clients $ name ++ " has connected"
                return $ return ()
            Just victim -> do
                broadcastNotice clients $
                    name ++ " has connected (kicking previous client)"
                clientSend victim $
                    "Another client by the name of " ++ name ++ " has connected"
                return $ killThread $ clientThreadId victim

    return client

deleteClient :: ClientMap -> Name -> Client -> IO ()
deleteClient clients name client =
    atomically $ do
        m <- readTVar clients
        case M.lookup name m of
            Nothing ->
                -- I got kicked already.  Do nothing.
                return ()
            Just c ->
                -- Make sure the client in the map is actually me, and not
                -- another client who took my name.
                if clientThreadId c == clientThreadId client
                    then do
                        broadcastNotice clients $ name ++ " has disconnected"
                        writeTVar clients $ M.delete name m
                    else return ()

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
                else bracket (insertClient clients name $ send duplex)
                             (deleteClient clients name)
                    $ \_ -> forever $ atomically $
                                recv duplex >>= broadcastMessageFrom clients name

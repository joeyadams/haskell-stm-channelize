-- |
-- Module:      Control.Concurrent.STM.Channelize
-- Copyright:   (c) Joseph Adams 2012
-- Maintainer:  joeyadams3.14159@gmail.com
-- Portability: base >= 4.3
--
-- Wrap a network connection such that sending and receiving can be done via
-- STM transactions.

{-# LANGUAGE CPP, DeriveDataTypeable #-}
module Control.Concurrent.STM.Channelize (
    -- * Using TDuplex for transactional I/O
    TDuplex,
    recv,
    send,
    sendE,

    -- * Configuring a connection
    ChannelizeConfig(..),
    connectStdio,
    connectHandle,

    -- * The channelize function
    channelize,

    -- * Exceptions
    ChannelizeException(..),
) where

import Prelude hiding (catch)
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.IORef
import Data.Typeable
import System.IO

data TDuplex msg_in msg_out
    = TDuplex
        { tdRecvStatus :: TVar WorkerStatus
        , tdRecvChan   :: TChan msg_in
        , tdSendStatus :: TVar WorkerStatus
        , tdSendChan   :: TChan msg_out
        , tdStop       :: TVar Bool
        }

-- | Read a message from the receive queue.  'retry' if no message is available
-- yet.
--
-- This will throw an exception if the reading thread encountered an error, or
-- if the connection is closed.
recv :: TDuplex msg_in msg_out -> STM msg_in
recv td =
    readTChan (tdRecvChan td) `orElse` do
        s <- readTVar $ tdRecvStatus td
        case s of
            Running -> retry
            Stopped -> throwSTM ChannelizeClosedRecv
            Error e -> throwSTM e

-- | Write a message to the send queue.
--
-- If an error occurred while sending a previous message, or if the connection
-- is closed, 'send' silently ignores the message and returns.  Rationale:
-- suppose you have threads for clients A and B.  A sends a message to B.  If
-- 'send' threw an exception on failure, you might inadvertently disconnect A
-- because of a failure that is B's fault.
send :: TDuplex msg_in msg_out -> msg_out -> STM ()
send td msg = sendReturnThrow td msg >> return ()

-- | Like 'send', but throw an exception if the message was discarded (either
-- because 'sendMsg' failed on a previous message, or because the connection
-- has been closed).
sendE :: TDuplex msg_in msg_out -> msg_out -> STM ()
sendE td msg = join $ sendReturnThrow td msg

sendReturnThrow :: TDuplex msg_in msg_out -> msg_out -> STM (STM ())
sendReturnThrow td msg = do
    s <- readTVar $ tdSendStatus td
    case s of
        Running -> do
            stopped <- readTVar (tdStop td)
            if stopped
                then
                    return $ throwSTM ChannelizeClosedSend
                else do
                    writeTChan (tdSendChan td) msg
                    return $ return ()
        Stopped ->
            return $ throwSTM ChannelizeClosedSend
        Error e ->
            return $ throwSTM e

data ChannelizeException
    = ChannelizeClosedRecv
    | ChannelizeClosedSend
    deriving Typeable

instance Show ChannelizeException where
    show ChannelizeClosedRecv = "channelize: receive callback used after connection was closed"
    show ChannelizeClosedSend = "channelize: send callback used after connection was closed"

instance Exception ChannelizeException

data ChannelizeKill
    = ChannelizeKill
    deriving (Show, Typeable)

instance Exception ChannelizeKill

data WorkerStatus = Running
                  | Stopped
                  | Error SomeException

-- | Callbacks telling 'channelize' how to use a duplex connection.
data ChannelizeConfig msg_in msg_out
    = ChannelizeConfig
        { recvMsg   :: IO msg_in
        , sendMsg   :: msg_out -> IO ()
            -- ^ Callbacks for sending and receiving messages.  All calls of
            -- 'recvMsg' will be in one thread, and all calls of 'sendMsg' will
            -- be in another thread.  If 'recvMsg' throws an exception, it will
            -- not be called again.  If 'sendMsg' throws an exception, it will
            -- not be called again, nor will 'sendBye' be called.
            --
            -- This means it is safe to use an 'IORef' to pass state from one
            -- 'recvMsg' or 'sendMsg' call to the next.  However, to share
            -- state between 'recvMsg' and 'sendMsg', you will need to use
            -- thread synchronization (e.g. 'MVar', 'STM').
        , sendBye   :: IO ()
            -- ^ Action to call before closing the connection, but only if none
            -- of the send calls failed.  This is called from the same thread
            -- as 'sendMsg'.
        , connClose :: IO ()
            -- ^ Callback for closing the connection.  Called when 'channelize'
            -- completes.
        }

-- | Treat 'stdin' and 'stdout' as a \"connection\", where each message
-- corresponds to a line.
--
-- This sets the buffering mode of 'stdin' and 'stdout' to 'LineBuffering'.
connectStdio :: IO (ChannelizeConfig String String)
connectStdio = do
    hSetBuffering stdin LineBuffering
    hSetBuffering stdout LineBuffering
    return ChannelizeConfig
        { recvMsg   = getLine
        , sendMsg   = putStrLn
        , sendBye   = return ()
        , connClose = return ()
        }

-- | Wrap a duplex 'Handle' in a 'ChannelizeConfig'.  Each message corresponds
-- to a line.
--
-- Example (client):
--
--  >let connect = connectTo "localhost" (PortNumber 1234) >>= connectHandle
--  > in channelize connect $ \duplex -> do
--  >        ...
--
-- Example (Telnet server):
--
--  >(handle, host, port) <- accept sock
--  >putStrLn $ "Accepted connection from " ++ host ++ ":" ++ show port
--  >
--  >-- Swallow carriage returns sent by telnet clients
--  >hSetNewlineMode handle universalNewlineMode
--  >
--  >forkIO $ channelize (connectHandle handle) $ \duplex -> do
--  >    ...
connectHandle :: Handle -> IO (ChannelizeConfig String String)
connectHandle h = do
    hSetBuffering h LineBuffering `onException` hClose h
    return ChannelizeConfig
        { recvMsg   = hGetLine h
        , sendMsg   = hPutStrLn h
        , sendBye   = return ()
        , connClose = hClose h
        }

channelize :: (IO (ChannelizeConfig msg_in msg_out))
                -- ^ Connect action.  It is run inside of an asynchronous
                --   exception 'mask'.
           -> (TDuplex msg_in msg_out -> IO a)
           -> IO a
channelize connect inner = do
    recv_chan   <- newTChanIO
    send_chan   <- newTChanIO
    stop        <- newTVarIO False
    recv_status <- newTVarIO Running
    send_status <- newTVarIO Running

    let tduplex =
            TDuplex
                { tdRecvStatus  = recv_status
                , tdRecvChan    = recv_chan
                , tdSendStatus  = send_status
                , tdSendChan    = send_chan
                , tdStop        = stop
                }

    mask $ \restore -> do
        config <- connect

        let recvLoop = do
                msg <- recvMsg config
                join $ atomically $ do
                    s <- readTVar stop
                    if s
                        then do
                            writeTVar recv_status Stopped
                            return $ return ()
                        else do
                            writeTChan recv_chan msg
                            return recvLoop

            sendLoop = join $ atomically $
                (do msg <- readTChan send_chan
                    return $ do
                        sendMsg config msg
                        sendLoop
                ) `orElse`
                (do s <- readTVar stop
                    if s
                        then return $ do
                            sendBye config
                            atomically $ writeTVar send_status Stopped
                        else retry
                )

            setError status_var e =
                case fromException e of
                    Just ChannelizeKill -> writeTVar status_var Stopped
                    _                   -> writeTVar status_var $ Error e

        recver <- forkIO $ recvLoop
                    `catch` (atomically . setError recv_status)

        sender <- forkIO $ sendLoop
                    `catch` (atomically . setError send_status)

        let finish = do
                atomically $ writeTVar stop True
                _ <- forkIO $ killSenderAfter 1000000
                throwTo recver ChannelizeKill `finally` waitForWorkers
                                              `finally` connClose config

            killSenderAfter usec = do
                -- I would use 'registerDelay', but it requires -threaded
                timeout <- newTVarIO False
                _ <- forkIO $ do
                    threadDelay usec
                    atomically $ writeTVar timeout True

                join $ atomically $ do
                    s <- readTVar send_status
                    case s of
                        Running -> do
                            t <- readTVar timeout
                            if t
                                then return $ throwTo sender ChannelizeKill
                                else retry
                        _ ->
                            -- Sender thread stopped.  Don't kill it.
                            return $ return ()

            waitForWorkers = atomically $ do
                r <- readTVar recv_status
                s <- readTVar send_status
                case (r, s) of
                    (Running, _) -> retry
                    (_, Running) -> retry
                    _            -> return ()

        r <- restore (inner tduplex) `onException` finish
        finish
        return r

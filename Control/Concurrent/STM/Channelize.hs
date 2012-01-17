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
    ChannelizeConfig(..),
    connectStdio,
    connectHandle,
    channelize,
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

connectHandle :: IO Handle -> IO (ChannelizeConfig String String)
connectHandle connect = do
    h <- connect
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
           -> (STM msg_in -> (msg_out -> STM ()) -> IO a)
           -> IO a
channelize connect inner = do
    chan_recv   <- newTChanIO
    chan_send   <- newTChanIO
    stop        <- newTVarIO False
    recv_status <- newTVarIO Running
    send_status <- newTVarIO Running

    let recv = readTChan chan_recv `orElse` do
            s <- readTVar recv_status
            case s of
                Running -> retry
                Stopped -> throwSTM ChannelizeClosedRecv
                Error e -> throwSTM e

        send msg = do
            s <- readTVar send_status
            case s of
                Running -> writeTChan chan_send msg
                Stopped -> throwSTM ChannelizeClosedSend
                Error e -> throwSTM e

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
                            writeTChan chan_recv msg
                            return recvLoop

            sendLoop = join $ atomically $ do
                s <- readTVar stop
                if s
                    then return $ do
                        sendBye config
                        atomically $ writeTVar send_status Stopped
                    else do
                        msg <- readTChan chan_send
                        return $ do
                            sendMsg config msg
                            sendLoop

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

        r <- restore (inner recv send) `onException` finish
        finish
        return r

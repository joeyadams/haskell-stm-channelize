-- |
-- Module:      Control.Concurrent.STM.Channelize
-- Copyright:   (c) Joseph Adams 2012
-- Maintainer:  joeyadams3.14159@gmail.com
-- Portability: base >= 4.3
--
-- Wrap a network connection such that sending and receiving can be done via
-- STM transactions.
--
-- See 'connectHandle' for basic usage.  See the @examples@ directory of this
-- package for full examples.

{-# LANGUAGE CPP, DeriveDataTypeable #-}
module Control.Concurrent.STM.Channelize (
    -- * The channelize function
    channelize,

    -- * Using TDuplex for transactional I/O
    TDuplex,
    recv,
    send,
    sendE,

    -- * Configuring a connection
    ChannelizeConfig(..),
    connectStdio,
    connectHandle,
    connectHandlePair,

    -- ** Closing individual sides of a duplex Handle
    -- $closing
    hCloseRead,
    hCloseWrite,

    -- * Exceptions
    ChannelizeException(..),
) where

import Prelude hiding (catch, log)
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.IORef
import Data.Typeable
import System.IO

-- Scary imports needed for hCloseRead and hCloseWrite
import GHC.IO.Handle.Types
    ( Handle(FileHandle, DuplexHandle)
    , Handle__
    )
import GHC.IO.Handle.Internals
    ( augmentIOError
    , hClose_help
    , withHandle'
    )

-- | An abstract object that supports sending and receiving messages in STM.
--
-- Internally, it is a pair of 'TChan's, with additional flags to check for I/O
-- errors on 'recv', and to avoid filling the send queue with messages that
-- will never be sent.
data TDuplex msg_in msg_out
    = TDuplex
        { tdRecvStatus :: TVar WorkerStatus
        , tdRecvChan   :: TChan msg_in
        , tdSendStatus :: TVar WorkerStatus
        , tdSendChan   :: TChan msg_out
        , tdStop       :: TVar Bool
        }

{- |
Read a message from the receive queue.  'retry' if no message is available yet.

This will throw an exception if the reading thread encountered an error, or if
the connection is closed.

Remember that STM transactions have no effect until they commit.  Thus, to send
a message and wait for a response, you will need to use two separate
transactions:

@
'atomically' $ 'send' duplex \"What is your name?\"
name <- 'atomically' $ 'recv' duplex
@
-}
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
-- 'send' were to throw an exception on failure, you might inadvertently
-- disconnect A because of a failure that is B's fault.
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
        , recvClose :: IO ()
        , sendClose :: IO ()
            -- ^ Close individual ends of the connection.  'recvClose' and
            -- 'sendClose' are called from the same threads as 'recvMsg' and
            -- 'sendMsg' respectively.
            --
            -- See 'hCloseRead' and 'hCloseWrite'.
        , connClose :: IO ()
            -- ^ Callback for closing the connection.  Called when 'channelize'
            -- completes, after 'recvClose' and 'sendClose' have been called.
        , context :: String
        }

-- | Treat 'stdin' and 'stdout' as a \"connection\", where each message
-- corresponds to a line.
--
-- This sets the buffering mode of 'stdin' and 'stdout' to 'LineBuffering'.
--
-- Be warned that this closes 'stdin' and 'stdout' upon completion.
connectStdio :: IO (ChannelizeConfig String String)
connectStdio = do
    c <- connectHandlePair stdin stdout
    return c {context = "connectStdio"}

-- | Like 'connectStdio', but use arbitrary input and output handles.
--
-- @'connectStdio' = 'connectHandlePair' 'stdin' 'stdout'@
connectHandlePair :: Handle     -- ^ Input
                  -> Handle     -- ^ Output
                  -> IO (ChannelizeConfig String String)
connectHandlePair input output = do
    hSetBuffering input LineBuffering
    hSetBuffering output LineBuffering
    return ChannelizeConfig
        { recvMsg   = hGetLine input
        , sendMsg   = hPutStrLn output
        , sendBye   = return ()
        , recvClose = do
            hPutStrLn stderr $ "connectHandlePair: hClose input"
            hClose input
            hPutStrLn stderr $ "connectHandlePair: hClose input complete"
        , sendClose = do
            hPutStrLn stderr $ "connectHandlePair: hClose output"
            hClose output
            hPutStrLn stderr $ "connectHandlePair: hClose output complete"
        , connClose = do
            hPutStrLn stderr $ "connectHandlePair: connClose"
            hClose output >> hClose input
            hPutStrLn stderr $ "connectHandlePair: connClose complete"
        , context = "connectHandlePair"
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
    hSetBuffering stderr LineBuffering
    return ChannelizeConfig
        { recvMsg   = hGetLine h
        , sendMsg   = hPutStrLn h
        , sendBye   = return ()
        , recvClose = hPutStrLn stderr "connectHandle: hCloseRead"
                   >> hCloseRead h
                   >> hPutStrLn stderr "connectHandle: hCloseRead complete"
        , sendClose = hPutStrLn stderr "connectHandle: hCloseWrite"
                   >> hCloseWrite h
                   >> hPutStrLn stderr "connectHandle: hCloseWrite complete"
        , connClose = hClose h
        , context = "connectHandle"
        }

{- $closing
Close individual ends of a duplex 'Handle'.  The rationale is that on some
platforms (namely, Windows with -threaded), a thread blocked reading from a
'Handle' cannot be interrupted.  This means if two hosts on Windows want to
disconnect from each other, one of them needs to send EOF first.  'hClose'
tries to close the read end before trying to close the write end, and 'hClose'
will block if another thread is using the connection.

'hCloseWrite' makes it possible for the write end to be closed first, allowing
the receiver to see EOF and close its end, too.

'hCloseRead' and 'hCloseWrite' have no effect on file handles.
-}

-- These functions are based on the source code to hClose.  If this code
-- breaks, look there to see what changed.

-- | Close only the read end of a duplex 'Handle'.
hCloseRead :: Handle -> IO ()
hCloseRead (FileHandle _ _) =
    return ()
hCloseRead h@(DuplexHandle _ r _) =
    withAugmentIOError "hCloseRead" h $
        hClose' h r

-- | Close only the write end of a duplex 'Handle'.
hCloseWrite :: Handle -> IO ()
hCloseWrite (FileHandle   _ _) =
    return ()
hCloseWrite h@(DuplexHandle _ _ w) =
    withAugmentIOError "hCloseWrite" h $
        hClose' h w

withAugmentIOError :: String -> Handle -> IO (Maybe SomeException) -> IO ()
withAugmentIOError fname h inner =
    mask $ \restore -> do
        maybe_ex <- restore inner
        case maybe_ex of
            Nothing -> return ()
            Just e ->
                case fromException e of
                    Just ioe -> ioError (augmentIOError ioe fname h)
                    Nothing  -> throwIO e

hClose' :: Handle -> MVar Handle__ -> IO (Maybe SomeException)
hClose' h m = withHandle' "hClose" h m hClose_help


-- | Open a connection, and manage it so it can be used as a 'TDuplex'.
--
-- This works by spawning two threads, one which receives messages and another
-- which sends messages.  If the 'recvMsg' callback throws an exception, it
-- will be forwarded to the next 'recv' call (once the receive queue is empty).
--
-- When the inner computation completes (or throws an exception), the send
-- queue is flushed and the connection is closed.
channelize :: IO (ChannelizeConfig msg_in msg_out)
                -- ^ Connect action.  It is run inside of an asynchronous
                --   exception 'mask'.
           -> (TDuplex msg_in msg_out -> IO a)
                -- ^ Inner computation.  When this completes or throws an
                -- exception, the connection will be closed.
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
                let log msg = uninterruptibleMask_
                            $ hPutStrLn stderr
                            $ "recvLoop <" ++ context config ++ ">: " ++ msg
                log "recvMsg"
                msg <- recvMsg config
                log "recvMsg done"
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

            runLoop x_status x_close x_loop =
                forkIO $ do
                    maybe_ex <- try x_loop
                    case maybe_ex of
                        Right _ ->
                            return ()
                        Left e ->
                            atomically $ writeTVar x_status $
                                case fromException e of
                                    Just ChannelizeKill -> Stopped
                                    _                   -> Error e
                    x_close config
                        `catch` \ChannelizeKill -> x_close config

        recver  <- runLoop recv_status recvClose recvLoop
        _sender <- runLoop send_status sendClose sendLoop

        let finish = do
                let log msg = uninterruptibleMask_
                            $ hPutStrLn stderr
                            $ "channelize.finish <" ++ context config ++ ">: " ++ msg

                log "Signalling stop"
                atomically $ writeTVar stop True

                -- Wait for the sender and receiver threads to finish.  This
                -- ensures that all enqueued data is sent before 'channelize'
                -- completes.
                --
                -- If we receive any asynchronous exceptions after this point,
                -- too bad... the connection won't be properly closed.
                log "Killing receiver"
                throwTo recver ChannelizeKill
                log "Waiting for workers"
                waitForWorkers
                log "Closing connection"
                connClose config
                log "Done"

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

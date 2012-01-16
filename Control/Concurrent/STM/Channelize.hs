-- |
-- Module:      Control.Concurrent.STM.Channelize
-- Copyright:   (c) Joseph Adams 2012
-- Maintainer:  joeyadams3.14159@gmail.com
-- Portability: base >= 4.3
--
-- Wrap a network connection such that sending and receiving can be done via
-- channels in STM.
--
-- This simplifies asynchronous I/O by making send and receive operations seem
-- atomic.  If a thread is thrown an exception while reading from or writing to
-- a TChan, the transaction will be rolled back thanks to STM.  Only if the
-- connection takes too long to respond during shutdown will a transmission be
-- truncated.
--
-- TODO: Add support for bounded-tchan.

{-# LANGUAGE CPP, DeriveDataTypeable #-}
module Control.Concurrent.STM.Channelize (
    Config(..),
    channelize,
    ChannelizeException(..),

    -- * Custom channel types
    -- | You may want to use a different type of channel than 'TChan' (e.g.
    -- TBChan in the stm-chans package).  'TChan' places no limit on the queue
    -- length, so your application may start leaking memory if a client
    -- produces messages faster than they can be consumed.
    --
    -- TODO
) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception as E
import Control.Monad
import Data.IORef
import Data.Typeable

data ChannelizeException
    = RecvError SomeException
    | SendError SomeException
    deriving Typeable

instance Show ChannelizeException where
    show (RecvError e) = "channelize: receive error: " ++ show e
    show (SendError e) = "channelize: send error: "    ++ show e

instance Exception ChannelizeException

data ChannelizeKill
    = ChannelizeKill
    deriving (Show, Typeable)

data Config msg_in msg_out
    = Config
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

-- | Turn a network connection's send and receive actions into a pair of 'TChan's.
--
-- More precisely, spawn two threads:
--
--  (1) Receive messages from the connection and write them to the first channel.
--
--  (2) Read messages from the second channel and send them to the connection.
--
-- Run the inner computation, passing it these channels.  When the computation
-- completes (or throws an exception), sending and receiving will stop, and the
-- connection will be closed.  Subsequent use of the channels will block and/or
-- leak memory.
--
-- If either the receive callback or send callback encounters an exception, it
-- will be wrapped in a 'ChannelizeException' and thrown to your thread.
--
-- Before returning, 'channelize' will wait for sending and receiving to stop, and for 
channelize :: Config msg_in msg_out
                -- ^ Callbacks for sending and receiving on the connection, and
                -- for closing the connection
           -> (TChan msg_in -> TChan msg_out -> IO a)
                -- ^ Inner computation
           -> IO a
channelize config inner = do
    recv_chan       <- newTChanIO
    send_chan       <- newTChanIO
    stop            <- newTVarIO False
    recv_stopped    <- newTVarIO False
    send_stopped    <- newTVarIO False
    killer_stopped  <- newTVarIO False
    caller_tid      <- myThreadId
    caller_gate     <- newGate

    let
        -- recvLoop and sendLoop terminate without exception if they detect
        -- that the stop variable is set.
        recvLoop = do
            msg <- recvMsg config
            checkVar stop (writeTVar recv_stopped True) $ do
                writeTChan recv_chan msg
                return recvLoop

        -- TODO: Do sendBye before marking send_stopped
        sendLoop =
            checkVar stop (writeTVar send_stopped True) $ do
                msg <- readTChan send_chan
                return $ do
                    sendMsg config msg
                    sendLoop

        runLoop :: IO ()
                -> (SomeException -> ChannelizeException)
                -> TVar Bool
                -> IO ThreadId
        runLoop loop e_wrapper x_stopped =
                forkIO $ mask $ \restore -> restore loop `catch` handler
            where
                handler e = do
                    atomically $ writeTVar x_stopped True
                    if fromException e == Just ChannelizeKill
                        then return ()
                        else whenGateIsOpen caller_gate $
                                throwTo caller_tid $ e_wrapper e

    mask $ \restore -> do
        recv_tid <- restore $ runLoop recvLoop RecvError recv_stopped
        send_tid <- restore $ runLoop sendLoop SendError send_stopped

        _killer_tid <- forkIO $ do
            waitFor stop

            -- Send ChannelizeKill to the receive thread immediately.
            -- Unfortunately, we don't know whether it is polling or receiving
            -- data.
            throwTo recv_tid ChannelizeKill

            -- Wait for the send thread to get our message.  This will usually
            -- succeed immediately, but if it takes too long, kill it.
            --
            -- Wait for the receive thread to finish being killed.  If it takes
            -- too long, move on.
            waitForDelay 1000000 [send_stopped, recv_stopped] $ do
                throwTo send_tid ChannelizeKill

                -- Give the send thread one more chance to stop, so 'close' hopefully 

            connClose config `finally` (atomically $ writeTVar killer_stopped True)

        restore (inner recv_chan send_chan) `onException` do
            atomically $ writeTVar stop True
            closeGate caller_gate
            waitFor killer_stopped

        atomically $ writeTVar stop True
        waitFor killer_stopped `onException` closeGate caller_gate
        closeGate caller_gate


------------------------------------------------------------------------
-- Gate

-- | A special type of mutex used to prevent send and receive threads from
-- throwing exceptions at the caller thread after 'channelize' has completed.
newtype Gate = Gate (MVar Bool)

-- | Create a new, open gate.
newGate :: IO Gate
newGate = Gate `fmap` newMVar True

-- | Perform an action, but only if the gate is open.
whenGateIsOpen :: Gate -> IO () -> IO ()
whenGateIsOpen (Gate gate) action =
    withMVar gate $ \open ->
        if open
            then action
            else return ()

-- | Close the gate.  This will never throw an exception.  If any asynchronous
-- exceptions are received during the operation, the first one is returned.
--
-- This must be run within an asynchronous exception 'mask'.
closeGate :: Gate -> IO (Maybe SomeException)
closeGate (Gate gate) =
        loop Nothing
    where
        loop prev_ex = do
            e <- try (takeMVar gate)
            case e of
                Left ex ->
                    loop (prev_ex `mplus` Just ex)
                Right _ -> do
                    putMVar gate False
                    return prev_ex


------------------------------------------------------------------------
-- Miscellaneous helpers

-- | Wait for the TVar's value to become 'True'.
waitFor :: TVar Bool -> IO ()
waitFor var = atomically $ do
    v <- readTVar var
    if v
        then return ()
        else retry

-- | If var is True, call on_set.  Otherwise, run or_else followed by the IO
-- action it returns.
--
-- If or_else retries, check var again.
checkVar :: TVar Bool -> STM () -> STM (IO ()) -> IO ()
checkVar var on_set or_else =
    join $ atomically $
        (do v <- readTVar var
            if v
                then on_set >> return (return ())
                else retry
        ) `orElse` or_else

-- | Like 'onException', but provide the exception to the caller.
onSomeException :: IO a -> (SomeException -> IO b) -> IO a
onSomeException action handler =
    action `catch` \e -> do
        _ <- handler e
        throwIO e

-- |
-- Module:      Control.Concurrent.STM.Channelize
-- Copyright:   (c) Joseph Adams 2012
-- Maintainer:  joeyadams3.14159@gmail.com
-- Portability: Requires STM, CPP, DeriveDataTypeable
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
    channelize,
    ChannelizeException(..),
) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception as E
import Control.Monad
import Data.Typeable

data ChannelizeException
    = RecvError SomeException
    | SendError SomeException
    deriving Typeable

instance Show ChannelizeException where
    show (RecvError e) = "channelize: receive error: " ++ show e
    show (SendError e) = "channelize: send error: "    ++ show e

instance Exception ChannelizeException

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
-- It is guaranteed that:
--
--  * The receive callback is only called from thread (1).
--
--  * The send callback is only called from thread (2).
--
--  * Neither callback is called after 'channelize' completes or throws an
--    exception.
channelize :: IO msg_in             -- ^ Receive callback
           -> (msg_out -> IO ())    -- ^ Send callback
           -> IO ()                 -- ^ Close callback
           -> (TChan msg_in -> TChan msg_out -> IO a)
                                    -- ^ Inner computation
           -> IO a
channelize recv send close inner = do
    recv_chan       <- newTChanIO
    send_chan       <- newTChanIO
    stop            <- newTVarIO False
    recv_stopped    <- newTVarIO False
    send_stopped    <- newTVarIO False

    caller_tid <- myThreadId

    let
        -- recvLoop and sendLoop terminate without exception if they detect
        -- that the stop variable is set.
        recvLoop = do
            msg <- recv
            checkVar stop (writeTVar recv_stopped True) $ do
                writeTChan recv_chan msg
                return recvLoop

        sendLoop =
            checkVar stop (writeTVar send_stopped True) $ do
                msg <- readTChan send_chan
                return $ do
                    send msg
                    sendLoop

        recvThread send_tid = do
            undefined

        sendThread recv_tid = do
            undefined

    (recv_tid, send_tid) <- forkIO_pair recvThread sendThread

    undefined


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
-- Internal helpers


-- | Spawn two threads, passing them each other's thread IDs.
forkIO_pair :: (ThreadId -> IO ())
            -> (ThreadId -> IO ())
            -> IO (ThreadId, ThreadId)
forkIO_pair action1 action2 = do
    tid2_var <- newTVarIO Nothing

    tid1 <- forkIO $ join $ atomically $ do
        m <- readTVar tid2_var
        case m of
            Nothing   -> retry    -- Still waiting for the other thread's ID
            Just tid2 -> return $ action1 tid2

    tid2 <- forkIO $ action2 tid1

    atomically $ writeTVar tid2_var $ Just tid2
    return (tid1, tid2)

-- | Wait for a thread to set a TVar to True.  If it takes too long, kill it.
waitThenKill :: TVar Bool -> ThreadId -> IO ()
waitThenKill response tid = do
    let delay_length = 1000000

    waitThenDo delay_length response $ do
        killThread tid

        -- Give the thread a second chance to signal completion
        waitThenDo delay_length response (return ())

-- | Wait for the TVar's value to become True.  If it takes longer than the
-- given number of microseconds, perform the given action (otherwise, don't).
waitThenDo :: Int -> TVar Bool -> IO () -> IO ()
waitThenDo timeout var action = do
    delay <- registerDelay timeout
    checkVar var (return ()) $ do
        timed_out <- readTVar delay
        if timed_out
            then return action
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

-- | Like 'E.mask', but backported to base before version 4.3.0.
--
-- Note that the restore callback is monomorphic, unlike in 'E.mask'.  This
-- could be fixed by changing the type signature, but it would require us to
-- enable the RankNTypes extension.  This module doesn't need that
-- polymorphism, anyway.
portableMask :: ((IO a -> IO a) -> IO b) -> IO b
#if MIN_VERSION_base(4,3,0)
portableMask io = E.mask $ \restore -> io restore
#else
portableMask io = do
    b <- E.blocked
    E.block $ io $ \m -> if b then m else E.unblock m
#endif

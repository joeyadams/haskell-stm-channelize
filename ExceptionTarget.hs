-- |
--
-- Portability: base >= 4.3
--
-- > import ExceptionTarget (ExceptionTarget)
-- > import qualified ExceptionTarget as ET

{-# LANGUAGE ScopedTypeVariables #-}
module ExceptionTarget (
    ExceptionTarget,
    new,
    throw,
    pinch,
) where

import Control.Concurrent
import Control.Exception as E hiding (throw)

data ExceptionTarget = ExceptionTarget ThreadId (MVar Bool)

new :: IO ExceptionTarget
new = do
    my_tid <- myThreadId
    mutex  <- newMVar False
    return $ ExceptionTarget my_tid mutex

-- | If the target has been pinched, the exception will not be thrown.
throw :: Exception e => ExceptionTarget -> e -> IO ()
throw (ExceptionTarget tid mutex) ex =
    mask_ $ do
        pinched <- takeMVar mutex
        if pinched
            then return ()
            else throwTo tid ex `onException` putMVar mutex pinched
        putMVar mutex pinched

-- | Prevent a thread from receiving any more exceptions through this
-- ExceptionTarget.
--
-- Even if 'pinch' receives an asynchronous exception, it is guaranteed that the target thread will not 
pinch :: ExceptionTarget -> IO ()
pinch = mask_ . pinchBase

-- | Variant of 'pinch' that must be run within an exception mask.
pinchBase :: ExceptionTarget -> IO ()
pinchBase (ExceptionTarget _ mutex) = loop
    where
        -- Acquire the mutex and set the "pinched" flag, which is behind the
        -- mutex.  If this fails (meaning we received an asynchronous
        -- exception), try again.  Try as many times as it takes.  Propagate
        -- the first exception we received (if any).

        loop :: IO ()
        loop = do
            (takeMVar mutex >> return ()) `E.catch` loopEx
            putMVar mutex True

        loopEx :: SomeException -> IO ()
        loopEx ex = do
            (takeMVar mutex >> return ()) `E.catch` \(_ :: SomeException) -> loopEx ex
            putMVar mutex True
            throwIO ex

-- Make sure that:
--
--  * If the exception thrower itself encounters an exception, it does not
--    leave the exception lock in an invalid state.
--
--  * When the receiving thread sees that an exception is coming, it needs to
--    wait for it.  However, if the thrower doesn't successfully get the
--    exception out, it must wake the receiving thread so it stops waiting for
--    an exception.
--
--  * If another exception is thrown at the receiving thread, it must still
--    mark that it has completed and run the finalizer.
--
--  * Extra safety: make sure withExceptionBarrier still works if run within
--    mask, and make sure 'throwToMe' can be called from the same thread as is
--    being thrown to.


-- |
--
-- Portability: base >= 4.3
--
-- > import ExceptionTarget (ExceptionTarget)
-- > import qualified ExceptionTarget as ET
module ExceptionTarget (
    ExceptionTarget,
    newExceptionTarget,
    throwExceptionTarget,
    pinchExceptionTarget,
    withExceptionTarget,
) where

import Control.Concurrent
import Control.Exception hiding (throw)
import Data.IORef

data ExceptionTarget = ExceptionTarget ThreadId (MVar ()) (IORef Bool)

new :: IO ExceptionTarget
new = do
    my_tid   <- myThreadId
    mutex    <- newMVar ()
    finished <- newIORef False
    return (ExceptionTarget my_tid mutex finished)

-- | If the target has been pinched, the exception will not be thrown.
throw :: Exception e => ExceptionTarget -> e -> IO ()

-- | Prevent a thread from receiving any more exceptions through this
-- ExceptionTarget.
pinch :: ExceptionTarget -> IO ()
pinch = mask_ . pinchBase

-- This must be run in an exception mask.
pinchBase :: ExceptionTarget -> IO ()
pinchBase (ExceptionTarget _ mutex finished) = do
    -- Set the "finished" flag so 'throw' will stop throwing exceptions at us.
    -- 'throw' may be about to throw us an exception, but this guarantees that
    -- no calls to 'throw' after that will throw us an exception.
    atomicModifyIORef finished (\_ -> (True, ()))

    -- This sequence may look careless and naive, but:
    --
    --  * setFinished is called within an exception mask
    --
    --  * If takeMVar is interrupted, it will leave the MVar intact.
    --    Otherwise, withMVar would not be exception-safe.
    --
    --  * The putMVar is not interruptible, because the MVar is
    --    guaranteed to be empty after the takeMVar.
    takeMVar mutex
    putMVar mutex ()

-- | Create a function that throws an exception to the current thread.  Ensure
-- that if the exception throwing function is called after the inner
-- computation has completed, the exception will be discarded.
withExceptionBarrier :: ((SomeException -> IO ()) -> IO a)
                     -> IO a
withExceptionBarrier inner = do
    mutex    <- newMVar ()
    finished <- newIORef False
    my_tid   <- myThreadId

    let testFinished =
            atomicModifyIORef finished (\f -> (f, f))

        -- Set the 'finished' flag.  In case a 
        setFinished = do
            atomicModifyIORef finished (\_ -> (True, ()))

            -- This sequence may look careless and naive, but:
            --
            --  * setFinished is called within an exception mask
            --
            --  * If takeMVar is interrupted, it will leave the MVar intact.
            --    Otherwise, withMVar would not be exception-safe.
            --
            --  * The putMVar is not interruptible, because the MVar is
            --    guaranteed to be empty after the takeMVar.
            takeMVar mutex
            putMVar mutex ()

        throwToMe ex = mask_ $ do
            takeMVar mutex
            f <- testFinished
            if f
                then return ()
                else throwTo my_tid ex `onException` putMVar mutex ()
            putMVar mutex ()

    mask $ \restore -> do
        r <- restore (inner throwToMe) `onException` setFinished
        setFinished
        return r

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


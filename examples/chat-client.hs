import Control.Concurrent.STM
import Control.Concurrent.STM.Channelize
import Control.Monad
import Network

main :: IO ()
main =
    channelize (connectHandle $ connectTo "localhost" $ PortNumber 1234)
    $ \recv send ->
        channelize connectStdio
        $ \recvStdin sendStdin ->
            forever $ atomically $
                (recv >>= sendStdin) `orElse` (recvStdin >>= send)

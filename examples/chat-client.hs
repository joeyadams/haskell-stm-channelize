import Control.Concurrent.STM
import Control.Concurrent.STM.Channelize
import Control.Monad
import Network

main :: IO ()
main =
    channelize (connectHandle $ connectTo "localhost" $ PortNumber 1234)
    $ \conn ->
        channelize connectStdio
        $ \stdio ->
            forever $ atomically $
                (recv conn >>= send stdio) `orElse`
                (recv stdio >>= send conn)

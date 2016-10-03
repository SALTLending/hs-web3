{-# LANGUAGE FlexibleInstances #-}
-- |
-- Module      :  Network.JsonRpc
-- Copyright   :  Alexander Krupenkin 2016
-- License     :  BSD3
--
-- Maintainer  :  mail@akru.me
-- Stability   :  experimental
-- Portability :  POSIX / WIN32
--
-- Functions for implementing the client side of JSON-RPC 2.0.
-- See <http://www.jsonrpc.org/specification>.
--
module Network.Ethereum.Web3.JsonRpc (remote, MethodName) where

import Network.Ethereum.Web3.Types

import Network.HTTP.Client (httpLbs, newManager, requestBody, responseBody,
                            method, requestHeaders, parseRequest,
                            RequestBody(RequestBodyLBS))
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Control.Monad.Error.Class (throwError)
import Data.ByteString.Lazy (ByteString)
import Control.Monad.Trans.Reader (ask)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (liftM, (<=<))
import Control.Applicative ((<|>))
import Control.Monad.Trans (lift)
import qualified Data.Text as T
import Data.Default.Class (def)
import Data.Vector (fromList)
import Data.Text (Text)
import Data.Aeson

-- | Name of called method.
type MethodName = Text

-- | Remote call of JSON-RPC method.
-- Arguments of function are stored into @params@ request array.
remote :: Remote a => MethodName -> a
remote n = remote_ (call . Array . fromList)
  where connection body = do
            conf <- ask
            liftIO $ do
                manager <- newManager tlsManagerSettings
                request <- parseRequest (rpcUri conf)
                let request' = request
                             { requestBody = RequestBodyLBS body
                             , requestHeaders = [("Content-Type", "application/json")]
                             , method = "POST" }
                responseBody <$> httpLbs request' manager
        call = connection . encode . Request n 1

class Remote a where
    remote_ :: ([Value] -> Web3 ByteString) -> a

instance (ToJSON a, Remote b) => Remote (a -> b) where
    remote_ f x = remote_ (\xs -> f (toJSON x : xs))

handleRpcErr :: Either String a -> Web3 a
handleRpcErr (Right a) = return a
handleRpcErr (Left e)  = lift $ throwError (def { rpcError = Just e })

decodeResponse :: (ToJSON a, FromJSON a) => ByteString -> Web3 a
decodeResponse = handleRpcErr .
    (eitherDecode . encode <=< rpcErr . rsResult <=< eitherDecode)
  where rpcErr (Left e)  = Left (T.unpack (errMsg e))
        rpcErr (Right a) = Right a

instance (ToJSON a, FromJSON a) => Remote (Web3 a) where
    remote_ f = decodeResponse =<< f []

data Request = Request { rqMethod :: Text
                       , rqId     :: Int
                       , rqParams :: Value }

instance ToJSON Request where
    toJSON rq = object $ [ "jsonrpc" .= String "2.0"
                         , "method"  .= rqMethod rq
                         , "params"  .= rqParams rq
                         , "id"      .= rqId rq ]

data Response = Response
  { rsResult :: Either RpcError Value
  , rsId     :: Int
  } deriving (Show)

instance FromJSON Response where
    parseJSON = withObject "JSON-RPC response object" $
                \v -> Response <$>
                      (Right <$> v .: "result" <|> Left <$> v .: "error") <*>
                      v .: "id"

-- | JSON-RPC error.
data RpcError = RpcError
  { errCode :: Int
  , errMsg  :: Text
  , errData :: Maybe Value
  } deriving (Show, Eq)

instance FromJSON RpcError where
    parseJSON (Object v) = RpcError <$> v .: "code"
                                    <*> v .: "message"
                                    <*> v .:? "data"

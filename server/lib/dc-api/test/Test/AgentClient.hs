{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE UndecidableInstances #-}

module Test.AgentClient
  ( AgentIOClient (..),
    mkAgentIOClient,
    AgentClientConfig (..),
    mkAgentClientConfig,
    HasAgentClient,
    introduceAgentClient,
    getAgentClientConfig,
    AgentClientT,
    runAgentClientT,
  )
where

import Command (SensitiveOutputHandling (..))
import Control.Exception (throwIO)
import Control.Lens ((.~))
import Control.Monad.Catch (MonadThrow, throwM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader)
import Control.Monad.State.Class (get, modify')
import Control.Monad.State.Strict (StateT, evalStateT)
import Data.Aeson qualified as Aeson
import Data.Aeson.Lens (key)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.CaseInsensitive qualified as CI
import Data.Foldable (for_)
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Stack (HasCallStack)
import Hasura.Backends.DataConnector.API qualified as API
import Network.HTTP.Client qualified as HttpClient
import Network.HTTP.Types (HeaderName, Method, Status (..), statusIsSuccessful)
import Servant.API (NamedRoutes)
import Servant.Client (BaseUrl, Client, Response, defaultMakeClientRequest, hoistClient, mkClientEnv, runClientM)
import Servant.Client.Core (Request, RunClient (..))
import Servant.Client.Internal.HttpClient (clientResponseToResponse, mkFailureResponse)
import Test.HttpFile qualified as HttpFile
import Test.Sandwich (HasBaseContext, HasLabel, Label (..), LabelValue, NodeOptions (..), SpecFree, defaultNodeOptions, getContext, type (:>))
import Test.Sandwich.Contexts (getCurrentFolder)
import Test.Sandwich.Misc (ExampleT)
import Test.Sandwich.Nodes (introduce')
import Text.Printf (printf)
import Prelude

-------------------------------------------------------------------------------

newtype AgentIOClient = AgentIOClient (forall m. MonadIO m => Client m (NamedRoutes API.Routes))

configHeader :: HeaderName
configHeader = CI.mk "X-Hasura-DataConnector-Config"

mkHttpClientManager :: MonadIO m => SensitiveOutputHandling -> m HttpClient.Manager
mkHttpClientManager sensitiveOutputHandling =
  let settings = HttpClient.defaultManagerSettings {HttpClient.managerModifyRequest = pure . addHeaderRedaction sensitiveOutputHandling}
   in liftIO $ HttpClient.newManager settings

addHeaderRedaction :: SensitiveOutputHandling -> HttpClient.Request -> HttpClient.Request
addHeaderRedaction sensitiveOutputHandling request =
  case sensitiveOutputHandling of
    AllowSensitiveOutput -> request
    DisallowSensitiveOutput -> request {HttpClient.redactHeaders = HttpClient.redactHeaders request <> Set.singleton configHeader}

mkAgentIOClient :: MonadIO m => SensitiveOutputHandling -> BaseUrl -> m AgentIOClient
mkAgentIOClient sensitiveOutputHandling agentBaseUrl = do
  manager <- mkHttpClientManager sensitiveOutputHandling
  let clientEnv = mkClientEnv manager agentBaseUrl
  pure $ AgentIOClient $ hoistClient (Proxy @(NamedRoutes API.Routes)) (\m -> liftIO (runClientM m clientEnv >>= either throwIO pure)) API.apiClient

-------------------------------------------------------------------------------

data AgentClientConfig = AgentClientConfig
  { _accBaseUrl :: BaseUrl,
    _accHttpManager :: HttpClient.Manager,
    _accSensitiveOutputHandling :: SensitiveOutputHandling
  }

mkAgentClientConfig :: MonadIO m => SensitiveOutputHandling -> BaseUrl -> m AgentClientConfig
mkAgentClientConfig sensitiveOutputHandling agentBaseUrl = do
  manager <- mkHttpClientManager sensitiveOutputHandling
  pure $ AgentClientConfig agentBaseUrl manager sensitiveOutputHandling

-------------------------------------------------------------------------------

introduceAgentClient :: forall context m. (MonadIO m) => AgentClientConfig -> SpecFree (LabelValue "agent-client" AgentClientConfig :> context) m () -> SpecFree context m ()
introduceAgentClient agentConfig = introduce' nodeOptions "Introduce agent client" agentClientLabel (pure agentConfig) (const $ pure ())
  where
    nodeOptions =
      defaultNodeOptions
        { nodeOptionsVisibilityThreshold = 150,
          nodeOptionsCreateFolder = False,
          nodeOptionsRecordTime = False
        }

agentClientLabel :: Label "agent-client" AgentClientConfig
agentClientLabel = Label

type HasAgentClient context = HasLabel context "agent-client" AgentClientConfig

getAgentClientConfig :: (HasCallStack, HasAgentClient context, MonadReader context m) => m AgentClientConfig
getAgentClientConfig = getContext agentClientLabel

-------------------------------------------------------------------------------

data AgentClientState = AgentClientState
  { _acsConfig :: AgentClientConfig,
    _acsRequestCounter :: Int,
    -- | An optional "phase" name that can help disambiguate requests that happen in different phases
    -- of a test, for example for requests that happen in a "before" and "after" phase around a test
    _acsPhaseName :: Maybe Text
  }

newtype AgentClientT m a = AgentClientT (StateT AgentClientState m a)
  deriving newtype (Functor, Applicative, Monad, MonadThrow, MonadIO, MonadReader r)

runAgentClientT ::
  (Monad m, HasAgentClient context) =>
  -- | An optional "phase" name that can help disambiguate requests that happen in different phases
  -- of a test, for example for requests that happen in a "before" and "after" phase around a test
  Maybe Text ->
  AgentClientT (ExampleT context m) a ->
  ExampleT context m a
runAgentClientT phaseName (AgentClientT action) = do
  config <- getAgentClientConfig
  evalStateT action (AgentClientState config 0 phaseName)

-------------------------------------------------------------------------------

instance (MonadIO m, MonadThrow m, HasBaseContext context, MonadReader context m) => RunClient (AgentClientT m) where
  runRequestAcceptStatus = runRequestAcceptStatus'
  throwClientError clientError = throwM clientError

runRequestAcceptStatus' :: (MonadIO m, MonadThrow m, HasBaseContext context, MonadReader context m) => Maybe [Status] -> Request -> (AgentClientT m) Response
runRequestAcceptStatus' acceptStatus request = do
  AgentClientState {_acsConfig = AgentClientConfig {..}, ..} <- getClientState

  let phaseNamePrefix = maybe "" (<> "-") _acsPhaseName
  let filenamePrefix = printf "%s%02d" (Text.unpack phaseNamePrefix) _acsRequestCounter
  let clientRequest = addHeaderRedaction _accSensitiveOutputHandling $ defaultMakeClientRequest _accBaseUrl request

  testFolder <- getCurrentFolder
  for_ testFolder $ HttpFile.writeRequest _accBaseUrl clientRequest filenamePrefix
  incrementRequestCounter

  let redactResponseBody =
        case _accSensitiveOutputHandling of
          AllowSensitiveOutput -> id
          DisallowSensitiveOutput -> redactJsonResponse (HttpClient.method clientRequest) (HttpClient.path clientRequest)

  clientResponse <- liftIO $ HttpClient.httpLbs clientRequest _accHttpManager
  for_ testFolder $ HttpFile.writeResponse redactResponseBody clientResponse filenamePrefix

  let status = HttpClient.responseStatus clientResponse
  let response = clientResponseToResponse id clientResponse
  let goodStatus = case acceptStatus of
        Nothing -> statusIsSuccessful status
        Just good -> status `elem` good
  if goodStatus
    then pure $ response
    else throwClientError $ mkFailureResponse _accBaseUrl request response

getClientState :: Monad m => AgentClientT m AgentClientState
getClientState = AgentClientT get

incrementRequestCounter :: Monad m => AgentClientT m ()
incrementRequestCounter = AgentClientT $ modify' \state -> state {_acsRequestCounter = _acsRequestCounter state + 1}

redactJsonResponse :: Method -> ByteString -> Aeson.Value -> Aeson.Value
redactJsonResponse requestMethod requestPath =
  case requestMethod of
    "POST" | "/datasets/clones/" `BS.isPrefixOf` requestPath -> redactCreateCloneResponse
    _ -> id

redactCreateCloneResponse :: Aeson.Value -> Aeson.Value
redactCreateCloneResponse = key "config" .~ Aeson.String "<REDACTED>"

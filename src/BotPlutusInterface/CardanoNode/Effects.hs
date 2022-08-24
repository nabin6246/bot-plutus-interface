{-# LANGUAGE RankNTypes #-}

module BotPlutusInterface.CardanoNode.Effects (
  utxosAt,
  handleNodeQuery,
  runNodeQuery,
  NodeQuery (..),
) where

import BotPlutusInterface.CardanoNode.Query (
  NodeConn,
  NodeQueryError,
  QueryConstraint,
  connectionInfo,
  queryBabbageEra,
  toQueryError,
 )

import BotPlutusInterface.CardanoAPI (
  addressInEraToAny,
  fromCardanoTxOut,
 )
import BotPlutusInterface.Types (PABConfig)
import Cardano.Api (LocalNodeConnectInfo (..))
import Cardano.Api qualified as CApi
import Control.Lens (folded, to, (^..))
import Control.Monad.Freer (Eff, Members, interpret, runM, send, type (~>))
import Control.Monad.Freer.Reader (Reader, ask, runReader)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Either (firstEitherT, hoistEither, newEitherT, runEitherT)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Ledger.Address (Address)
import Ledger.Tx (ChainIndexTxOut (..))
import Ledger.Tx.CardanoAPI qualified as TxApi
import Plutus.V2.Ledger.Tx qualified as V2
import Prelude

data NodeQuery a where
  UtxosAt :: Address -> NodeQuery (Either NodeQueryError (Map V2.TxOutRef ChainIndexTxOut))

utxosAt ::
  forall effs.
  Members '[NodeQuery] effs =>
  Address ->
  Eff effs (Either NodeQueryError (Map V2.TxOutRef ChainIndexTxOut))
utxosAt = send . UtxosAt

handleNodeQuery ::
  forall effs.
  QueryConstraint effs =>
  Eff (NodeQuery ': effs) ~> Eff effs
handleNodeQuery =
  interpret $ \case
    UtxosAt addr -> handleUtxosAt addr

handleUtxosAt ::
  forall effs.
  QueryConstraint effs =>
  Address ->
  Eff effs (Either NodeQueryError (Map V2.TxOutRef ChainIndexTxOut))
handleUtxosAt addr = runEitherT $ do
  conn <- lift $ ask @NodeConn

  caddr <-
    firstEitherT toQueryError $
      hoistEither $
        TxApi.toCardanoAddressInEra (localNodeNetworkId conn) addr

  let query :: CApi.QueryInShelleyBasedEra era (CApi.UTxO era)
      query = CApi.QueryUTxO $ CApi.QueryUTxOByAddress $ Set.singleton $ addressInEraToAny caddr

  (CApi.UTxO result) <- newEitherT $ queryBabbageEra query

  chainIndexTxOuts <-
    firstEitherT toQueryError $
      hoistEither $
        sequenceA $
          result ^.. folded . to fromCardanoTxOut

  let txOutRefs :: [V2.TxOutRef]
      txOutRefs = TxApi.fromCardanoTxIn <$> Map.keys result

  return $ Map.fromList $ zip txOutRefs chainIndexTxOuts

runNodeQuery :: PABConfig -> Eff '[NodeQuery, Reader NodeConn, IO] ~> IO
runNodeQuery conf effs = do
  conn <- connectionInfo conf
  runM $
    runReader conn $
      handleNodeQuery effs

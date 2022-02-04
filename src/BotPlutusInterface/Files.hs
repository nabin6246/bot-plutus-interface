{-# LANGUAGE AllowAmbiguousTypes #-}

module BotPlutusInterface.Files (
  policyScriptFilePath,
  validatorScriptFilePath,
  readPrivateKeys,
  signingKeyFilePath,
  txFilePath,
  readPrivateKey,
  writeAll,
  writePolicyScriptFile,
  redeemerJsonFilePath,
  writeRedeemerJsonFile,
  writeValidatorScriptFile,
  datumJsonFilePath,
  fromCardanoPaymentKey,
  writeDatumJsonFile,
) where

import BotPlutusInterface.Effects (
  PABEffect,
  createDirectoryIfMissing,
  listDirectory,
  readFileTextEnvelope,
  writeFileJSON,
  writeFileTextEnvelope,
 )
import BotPlutusInterface.Types (PABConfig)
import Cardano.Api (
  AsType (AsPaymentKey, AsSigningKey),
  FileError,
  PaymentKey,
  SigningKey,
  getVerificationKey,
  serialiseToRawBytes,
 )
import Cardano.Api.Shelley (
  PlutusScript (PlutusScriptSerialised),
  PlutusScriptV1,
  ScriptDataJsonSchema (ScriptDataJsonDetailedSchema),
  fromPlutusData,
  scriptDataToJson,
 )
import Cardano.Crypto.Wallet qualified as Crypto
import Codec.Serialise qualified as Codec
import Control.Monad.Freer (Eff, Member)
import Data.Aeson qualified as JSON
import Data.Aeson.Extras (encodeByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Short qualified as ShortByteString
import Data.Either.Combinators (mapLeft)
import Data.Kind (Type)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Ledger qualified
import Ledger.Crypto (PrivateKey, PubKeyHash (PubKeyHash))
import Ledger.Tx (Tx)
import Ledger.Tx qualified as Tx
import Ledger.TxId qualified as TxId
import Ledger.Value qualified as Value
import Plutus.V1.Ledger.Api (
  CurrencySymbol,
  Datum (getDatum),
  DatumHash (..),
  MintingPolicy,
  Redeemer (getRedeemer),
  RedeemerHash (..),
  Script,
  Validator,
  ValidatorHash (..),
 )
import PlutusTx (ToData, toData)
import PlutusTx.Builtins (fromBuiltin)
import System.FilePath (isExtensionOf)
import Prelude

-- | Filename of a minting policy script
policyScriptFilePath :: PABConfig -> CurrencySymbol -> Text
policyScriptFilePath pabConf curSymbol =
  let c = encodeByteString $ fromBuiltin $ Value.unCurrencySymbol curSymbol
   in pabConf.pcScriptFileDir <> "/policy-" <> c <> ".plutus"

-- | Path and filename of a validator script
validatorScriptFilePath :: PABConfig -> ValidatorHash -> Text
validatorScriptFilePath pabConf (ValidatorHash valHash) =
  let h = encodeByteString $ fromBuiltin valHash
   in pabConf.pcScriptFileDir <> "/validator-" <> h <> ".plutus"

datumJsonFilePath :: PABConfig -> DatumHash -> Text
datumJsonFilePath pabConf (DatumHash datumHash) =
  let h = encodeByteString $ fromBuiltin datumHash
   in pabConf.pcScriptFileDir <> "/datum-" <> h <> ".json"

redeemerJsonFilePath :: PABConfig -> RedeemerHash -> Text
redeemerJsonFilePath pabConf (RedeemerHash redeemerHash) =
  let h = encodeByteString $ fromBuiltin redeemerHash
   in pabConf.pcScriptFileDir <> "/redeemer-" <> h <> ".json"

signingKeyFilePath :: PABConfig -> PubKeyHash -> Text
signingKeyFilePath pabConf (PubKeyHash pubKeyHash) =
  let h = encodeByteString $ fromBuiltin pubKeyHash
   in pabConf.pcSigningKeyFileDir <> "/signing-key-" <> h <> ".skey"

txFilePath :: PABConfig -> Text -> Tx.Tx -> Text
txFilePath pabConf ext tx =
  let txId = encodeByteString $ fromBuiltin $ TxId.getTxId $ Tx.txId tx
   in pabConf.pcTxFileDir <> "/tx-" <> txId <> "." <> ext

-- | Compiles and writes a script file under the given folder
writePolicyScriptFile ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  PABConfig ->
  MintingPolicy ->
  Eff effs (Either (FileError ()) Text)
writePolicyScriptFile pabConf mintingPolicy =
  let script = serialiseScript $ Ledger.unMintingPolicyScript mintingPolicy
      filepath = policyScriptFilePath pabConf (Ledger.scriptCurrencySymbol mintingPolicy)
   in fmap (const filepath) <$> writeFileTextEnvelope @w (Text.unpack filepath) Nothing script

-- | Compiles and writes a script file under the given folder
writeValidatorScriptFile ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  PABConfig ->
  Validator ->
  Eff effs (Either (FileError ()) Text)
writeValidatorScriptFile pabConf validatorScript =
  let script = serialiseScript $ Ledger.unValidatorScript validatorScript
      filepath = validatorScriptFilePath pabConf (Ledger.validatorHash validatorScript)
   in fmap (const filepath) <$> writeFileTextEnvelope @w (Text.unpack filepath) Nothing script

-- | Write to disk all validator scripts, datums and redemeers appearing in the tx
writeAll ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  PABConfig ->
  Tx ->
  Eff effs (Either (FileError ()) [Text])
writeAll pabConf tx = do
  createDirectoryIfMissing @w False (Text.unpack pabConf.pcScriptFileDir)

  let (validatorScripts, redeemers, datums) =
        unzip3 $ mapMaybe Tx.inScripts $ Set.toList $ Tx.txInputs tx

      policyScripts = Set.toList $ Ledger.txMintScripts tx
      allDatums = datums <> Map.elems (Tx.txData tx)
      allRedeemers = redeemers <> Map.elems (Tx.txRedeemers tx)

  results <-
    sequence $
      mconcat
        [ map (writePolicyScriptFile @w pabConf) policyScripts
        , map (writeValidatorScriptFile @w pabConf) validatorScripts
        , map (writeDatumJsonFile @w pabConf) allDatums
        , map (writeRedeemerJsonFile @w pabConf) allRedeemers
        ]

  pure $ sequence results

readPrivateKeys ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  PABConfig ->
  Eff effs (Either Text (Map PubKeyHash PrivateKey))
readPrivateKeys pabConf = do
  files <- listDirectory @w $ Text.unpack pabConf.pcSigningKeyFileDir
  let sKeyFiles =
        map (\filename -> Text.unpack pabConf.pcSigningKeyFileDir ++ "/" ++ filename) $
          filter ("skey" `isExtensionOf`) files
  privKeys <- mapM (readPrivateKey @w) sKeyFiles
  pure $ toPrivKeyMap <$> sequence privKeys
  where
    toPrivKeyMap :: [PrivateKey] -> Map PubKeyHash PrivateKey
    toPrivKeyMap =
      foldl
        ( \pKeyMap pKey ->
            let pkh = Ledger.pubKeyHash $ Ledger.toPublicKey pKey
             in Map.insert pkh pKey pKeyMap
        )
        Map.empty

readPrivateKey ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  FilePath ->
  Eff effs (Either Text PrivateKey)
readPrivateKey filePath = do
  pKey <- mapLeft (Text.pack . show) <$> readFileTextEnvelope @w (AsSigningKey AsPaymentKey) filePath
  pure $ fromCardanoPaymentKey =<< pKey

{- | Warning! This implementation is not correct!
 This private key is derived from a normal signing key which uses a 32 byte private key compared
 to the extended key which is 64 bytes. Also, the extended key includes a chain index value

 This keys sole purpose is to be able to derive a public key from it, which is then used for
 mapping to a signing key file for the CLI
-}
fromCardanoPaymentKey :: SigningKey PaymentKey -> Either Text PrivateKey
fromCardanoPaymentKey sKey =
  let dummyPrivKeySuffix = ByteString.replicate 32 0
      dummyChainCode = ByteString.replicate 32 1
      vKey = getVerificationKey sKey
      privkeyBS = serialiseToRawBytes sKey
      pubkeyBS = serialiseToRawBytes vKey
   in mapLeft Text.pack $
        Crypto.xprv $
          mconcat [privkeyBS, dummyPrivKeySuffix, pubkeyBS, dummyChainCode]

serialiseScript :: Script -> PlutusScript PlutusScriptV1
serialiseScript =
  PlutusScriptSerialised
    . ShortByteString.toShort
    . LazyByteString.toStrict
    . Codec.serialise

writeDatumJsonFile ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  PABConfig ->
  Datum ->
  Eff effs (Either (FileError ()) Text)
writeDatumJsonFile pabConf datum =
  let json = dataToJson $ getDatum datum
      filepath = datumJsonFilePath pabConf (Ledger.datumHash datum)
   in fmap (const filepath) <$> writeFileJSON @w (Text.unpack filepath) json

writeRedeemerJsonFile ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  PABConfig ->
  Redeemer ->
  Eff effs (Either (FileError ()) Text)
writeRedeemerJsonFile pabConf redeemer =
  let json = dataToJson $ getRedeemer redeemer
      filepath = redeemerJsonFilePath pabConf (Ledger.redeemerHash redeemer)
   in fmap (const filepath) <$> writeFileJSON @w (Text.unpack filepath) json

dataToJson :: forall (a :: Type). ToData a => a -> JSON.Value
dataToJson =
  scriptDataToJson ScriptDataJsonDetailedSchema . fromPlutusData . PlutusTx.toData
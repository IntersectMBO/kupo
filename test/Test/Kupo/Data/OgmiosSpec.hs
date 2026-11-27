-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE AllowAmbiguousTypes #-}

module Test.Kupo.Data.OgmiosSpec
    ( spec
    ) where

import Kupo.Prelude

import Control.Lens
    ( (.~)
    )
import Data.Aeson
    ( (.=)
    )
import Data.Aeson.Lens
    ( key
    , _String
    )
import Data.List
    ( (!!)
    )
import Kupo.App.ChainSync.Ogmios
    ( intersectionNotFound
    )
import Kupo.Data.Cardano
    ( BinaryData
    , Block
    , ComparableOutput
    , ComparableScript
    , DatumHash
    , HasTransactionId (..)
    , Input
    , InputIndex
    , IsBlock (..)
    , MetadataHash
    , OutputReference
    , ScriptHash
    , SlotNo (..)
    , Transaction (..)
    , TransactionId
    , UnsupportedSubTransactions (..)
    , hashScript
    , mkOutputReference
    , scriptHashToText
    , toComparableOutput
    , toComparableScript
    , transactionIdFromText
    )
import Kupo.Data.Ogmios
    ( NextBlockResponse (..)
    , PartialBlock
    , decodeFindIntersectionResponse
    , decodeNextBlockResponse
    )
import Kupo.Data.Pattern
    ( Codecs (..)
    , Match (..)
    , MatchBootstrap (..)
    , Pattern (..)
    , Result (..)
    , matchBlock
    )
import System.Directory
    ( listDirectory
    )
import System.FilePath
    ( (</>)
    )
import Test.Hspec
    ( Expectation
    , Spec
    , SpecWith
    , context
    , expectationFailure
    , it
    , parallel
    , runIO
    , shouldBe
    , shouldSatisfy
    )
import Test.Hspec.QuickCheck
    ( prop
    )
import Test.QuickCheck
    ( counterexample
    , withNumTests
    )
import Test.QuickCheck.Monadic
    ( assert
    , monadicIO
    , monitor
    , run
    )

import qualified Cardano.Ledger.Dijkstra.Core as Ledger
import qualified Data.Aeson as Json
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.Types as Json
import qualified Data.Map as Map
import qualified Data.Text as Text

spec :: Spec
spec = parallel $ context "can decode relevant Ogmios' test vectors" $ do
    context "decodeFindIntersectResponse" $ do
        let dir = "./test/vectors/ogmios/server/test/vectors/FindIntersectionResponse"
        vectors <- runIO (listDirectory dir)
        propVector ((dir </>) <$> vectors) (decodeFindIntersectionResponse $ intersectionNotFound [])

    context "decodeRequestNextResponse" $ do
        let dir = "./test/vectors/ogmios/server/test/vectors/NextBlockResponse"
        vectors <- runIO (listDirectory dir)
        propVector ((dir </>) <$> vectors) decodeNextBlockResponse

    context "decodeRequestNextResponse (extra golden)" $ do
        let dir = "./test/vectors/golden"
        vectors <- runIO (listDirectory dir)
        propVector ((dir </>) <$> vectors) decodeNextBlockResponse

    context "checkSubTransactions" $ do
        it "rejects a Dijkstra block whose transactions Ogmios sends without their bodies" $ do
            let stub = Json.object
                    [ "id" .= txId
                    , "spends" .= ("inputs" :: Text)
                    ]
            withBlock (nextBlock "dijkstra" [stub]) $ \blk ->
                checkSubTransactions blk `shouldSatisfy` \case
                    Left UnverifiableSubTransactions{} -> True
                    _ -> False

        it "accepts a Dijkstra block whose transactions Ogmios serialises in full" $ do
            tx <- goldenTransactionJson
            withBlock (nextBlock "dijkstra" [tx]) $ \blk ->
                checkSubTransactions blk `shouldSatisfy` isRight

        it "accepts a Conway block" $ do
            let tx = Json.object
                    [ "id" .= txId
                    , "spends" .= ("inputs" :: Text)
                    , "inputs" .= ([] :: [Json.Value])
                    , "outputs" .= ([] :: [Json.Value])
                    ]
            withBlock (nextBlock "conway" [tx]) $ \blk ->
                checkSubTransactions blk `shouldSatisfy` isRight

    context "sub-transactions" $ do
        it "reads a Dijkstra transaction and its sub-transactions as the node-to-client path does" $ do
            transactionJson <- goldenTransactionJson
            tx <- goldenTransaction
            withBlock (nextBlock "dijkstra" [transactionJson]) $ \blk -> do
                let views = foldBlock (\_ -> (:) . viewTransaction @PartialBlock) [] blk
                views `shouldBe` [viewTransaction @Block (TransactionDijkstra tx)]
                (fmap viewId . viewApplied <$> views) `shouldBe` [goldenSubTransactionIds]
                (fmap (fmap fst . viewProduced) . viewApplied <$> views) `shouldBe`
                    [ [ [ mkOutputReference sub0 0 ]
                      , [ mkOutputReference sub1 0, mkOutputReference sub1 1 ]
                      ]
                    ]

        it "matches the outputs and spends of sub-transactions under their top-level transaction" $ do
            transactionJson <- goldenTransactionJson
            withBlock (nextBlock "dijkstra" [transactionJson]) $ \blk -> do
                let Match{consumed, produced} = matchBlock codecs matchAll blk
                [ (outputReference, subTransactionOf) | Result{outputReference, subTransactionOf} <- produced ]
                    `shouldBe`
                    [ ((mkOutputReference sub0 0, 0), Just (goldenTransactionId, 0))
                    , ((mkOutputReference sub1 0, 0), Just (goldenTransactionId, 1))
                    , ((mkOutputReference sub1 1, 0), Just (goldenTransactionId, 1))
                    , ((mkOutputReference goldenTransactionId 0, 0), Nothing)
                    , ((mkOutputReference goldenTransactionId 1, 0), Nothing)
                    , ((mkOutputReference goldenTransactionId 2, 0), Nothing)
                    ]
                Map.keys consumed `shouldBe` sort
                    [ (goldenTransactionId, Nothing, SlotNo 42)
                    , (sub0, Just goldenTransactionId, SlotNo 42)
                    , (sub1, Just goldenTransactionId, SlotNo 42)
                    ]

        it "discards the sub-transactions of a phase-2 invalid transaction, but keeps their witnesses" $ do
            transactionJson <- goldenTransactionJson
            tx <- goldenTransaction
            let invalidJson = transactionJson & key "spends" . _String .~ "collaterals"
            let invalid = tx & Ledger.isPhase2ValidTxL .~ Ledger.Phase2Invalid
            withBlock (nextBlock "dijkstra" [invalidJson]) $ \blk -> do
                let views = foldBlock (\_ -> (:) . viewTransaction @PartialBlock) [] blk
                views `shouldBe` [viewTransaction @Block (TransactionDijkstra invalid)]
                (viewApplied <$> views) `shouldBe` [[]]
                (fmap viewId . viewDiscarded <$> views) `shouldBe` [goldenSubTransactionIds]
                let Match{consumed, produced} = matchBlock codecs matchAll blk
                -- The collateral return, indexed after the three outputs.
                [ (outputReference, subTransactionOf) | Result{outputReference, subTransactionOf} <- produced ]
                    `shouldBe` [((mkOutputReference goldenTransactionId 3, 0), Nothing)]
                consumed `shouldBe` fromList
                    [ ( (goldenTransactionId, Nothing, SlotNo 42)
                      , [(MatchOutputReference goldenCollateral, 0, Nothing)]
                      )
                    ]

    context "native scripts with a guard clause" $ do
        it "decodes them from their CBOR" $ do
            let tx = transactionWithScript scriptGuardHash $ Json.object
                    [ "language" .= ("native" :: Text)
                    , "json" .= guardClause []
                    , "cbor" .= scriptGuardCbor
                    ]
            withBlock (nextBlock "dijkstra" [tx]) $ \blk ->
                witnessedScriptHashes blk `shouldBe` [(scriptGuardHash, scriptGuardHash)]

        it "decodes a key guard from its JSON origin" $ do
            let tx = transactionWithScript keyGuardHash $ Json.object
                    [ "language" .= ("native" :: Text)
                    , "json" .= guardClause ["origin" .= ("verificationKey" :: Text)]
                    ]
            withBlock (nextBlock "dijkstra" [tx]) $ \blk ->
                witnessedScriptHashes blk `shouldBe` [(keyGuardHash, keyGuardHash)]

        it "decodes a script guard from its JSON origin" $ do
            let tx = transactionWithScript scriptGuardHash $ Json.object
                    [ "language" .= ("native" :: Text)
                    , "json" .= guardClause ["origin" .= ("script" :: Text)]
                    ]
            withBlock (nextBlock "dijkstra" [tx]) $ \blk ->
                witnessedScriptHashes blk `shouldBe` [(scriptGuardHash, scriptGuardHash)]

        it "refuses them without their CBOR or origin" $ do
            let tx = transactionWithScript scriptGuardHash $ Json.object
                    [ "language" .= ("native" :: Text)
                    , "json" .= guardClause []
                    ]
            void (Json.parseEither decodeNextBlockResponse (nextBlock "dijkstra" [tx]))
                `shouldSatisfy` isLeft

--
-- Helpers
--

withBlock :: Json.Value -> (PartialBlock -> Expectation) -> Expectation
withBlock value check =
    case Json.parse decodeNextBlockResponse value of
        Json.Success (RollForward _ blk) -> check blk
        Json.Success _ -> expectationFailure "expected a roll forward"
        Json.Error str -> expectationFailure str

nextBlock :: Text -> [Json.Value] -> Json.Value
nextBlock era txs = Json.object
    [ "result" .= Json.object
        [ "direction" .= ("forward" :: Text)
        , "tip" .= point
        , "block" .= Json.object
            [ "type" .= ("praos" :: Text)
            , "era" .= era
            , "id" .= blockId
            , "height" .= (1 :: Int)
            , "slot" .= (42 :: Int)
            , "transactions" .= txs
            ]
        ]
    ]
  where
    point = Json.object
        [ "id" .= blockId
        , "height" .= (1 :: Int)
        , "slot" .= (42 :: Int)
        ]

-- | What Kupo reads from a transaction through 'IsBlock', and from its sub-transactions.
data TransactionView = TransactionView
    { viewId :: !TransactionId
    , viewSpent :: ![(InputIndex, Input, Maybe BinaryData)]
    , viewProduced :: ![(OutputReference, ComparableOutput)]
    , viewDatums :: !(Map DatumHash BinaryData)
    , viewScripts :: !(Map ScriptHash ComparableScript)
    , viewMetadataHash :: !(Maybe MetadataHash)
    , viewApplied :: ![TransactionView]
    , viewDiscarded :: ![TransactionView]
    } deriving (Eq, Show)

viewTransaction
    :: forall block. IsBlock block
    => BlockBody block
    -> TransactionView
viewTransaction tx = TransactionView
    { viewId =
        getTransactionId tx
    , viewSpent =
        [ (ix, input, spendRedeemer @block tx ix)
        | (ix, input) <- zip [0 ..] (toList (spentInputs @block tx))
        ]
    , viewProduced =
        mapMaybeOutputs @block (\ref output _ -> Just (ref, toComparableOutput output)) tx
    , viewDatums =
        witnessedDatums @block tx
    , viewScripts =
        toComparableScript <$> witnessedScripts @block tx
    , viewMetadataHash =
        fst <$> userDefinedMetadata @block tx
    , viewApplied =
        viewTransaction @block <$> subTransactions @block tx
    , viewDiscarded =
        viewTransaction @block <$> discardedSubTransactions @block tx
    }

-- | The witnessed scripts of a block, with their key and their own hash.
witnessedScriptHashes :: PartialBlock -> [(Text, Text)]
witnessedScriptHashes =
    fmap (\(scriptHash, script) -> (scriptHashToText scriptHash, scriptHashToText (hashScript script)))
        . foldBlock (\_ -> (<>) . Map.toList . witnessedScripts @PartialBlock) []

matchAll :: Set Pattern
matchAll =
    fromList [MatchAny IncludingBootstrap]

codecs :: Codecs Result () () ()
codecs = Codecs
    { toResult = identity
    , toBinaryData = \_ _ -> ()
    , toScript = \_ _ -> ()
    , toPolicy = \_ _ -> ()
    }

propVector
    :: [FilePath]
    -> (Json.Value -> Json.Parser a)
    -> SpecWith ()
propVector vectors decoder = do
    prop "decode test vectors" $ withNumTests 1 $ monadicIO $ do
        forM_ [0 .. (length vectors) - 1] (\i -> shouldDecode (vectors !! i))
  where
    shouldDecode vector = do
        let errDecode = "Failed to decode JSON"
        value <- maybe (fail errDecode) pure =<< run (Json.decodeFileStrict vector)
        case Json.parse decoder value of
            Json.Error str -> do
                monitor $ counterexample (decodeUtf8 (Json.encode value))
                monitor $ counterexample str
                assert False
            Json.Success{} -> do
                assert True

--
-- Fixtures
--

txId :: Text
txId = Text.replicate 64 "a"

blockId :: Text
blockId = Text.replicate 64 "b"

-- | A Dijkstra transaction with two sub-transactions, from Ogmios' golden tests.
goldenTransactionJson :: IO Json.Value
goldenTransactionJson =
    either (error . toText) identity
        <$> Json.eitherDecodeFileStrict (goldenDir </> "Transaction_Dijkstra_1.json")

-- | The same transaction, from its CBOR.
goldenTransaction :: IO (Ledger.Tx Ledger.TopTx DijkstraEra)
goldenTransaction = do
    hex <- decodeUtf8 <$> readFileBS (goldenDir </> "Transaction_Dijkstra_1.cbor.hex")
    pure $ unsafeDecodeCborAnn @DijkstraEra "Tx" decCBOR (toLazy . unsafeDecodeBase16 $ Text.strip hex)

goldenDir :: FilePath
goldenDir =
    "./test/vectors/ogmios/server/test/golden"

goldenTransactionId :: TransactionId
goldenTransactionId =
    transactionIdFromHex "dd06f8c4006fc58269f8ad83e125308967960bd25ee1a55b8a1b5e94d98952da"

goldenSubTransactionIds :: [TransactionId]
goldenSubTransactionIds =
    [sub0, sub1]

sub0 :: TransactionId
sub0 =
    transactionIdFromHex "ccaef55f659113c69776852b314e0dd45577f49de1bd5ff16b5deac2b09f4672"

sub1 :: TransactionId
sub1 =
    transactionIdFromHex "03d34728298e26cf5c20a7a4159901abb391116b7c9dc86eb6665afec0a59f83"

goldenCollateral :: OutputReference
goldenCollateral =
    mkOutputReference
        (transactionIdFromHex "9b766aeeac195e946a70dd0785c80e585fdcee364aae5fed55ee2f7f5f337a20")
        0

transactionIdFromHex :: Text -> TransactionId
transactionIdFromHex hex =
    fromMaybe (error $ "invalid transaction id: " <> hex) (transactionIdFromText hex)

transactionWithScript :: Text -> Json.Value -> Json.Value
transactionWithScript scriptHash script = Json.object
    [ "id" .= txId
    , "spends" .= ("inputs" :: Text)
    , "inputs" .= ([] :: [Json.Value])
    , "scripts" .= Json.object [ Key.fromText scriptHash .= script ]
    ]

-- | A guard clause on the hash 11...11, with extra fields such as its 'origin'.
guardClause :: [Json.Pair] -> Json.Value
guardClause extra = Json.object $
    [ "clause" .= ("guard" :: Text)
    , "from" .= Text.replicate 28 "11"
    ]
    <> extra

-- | The guard clause on the script hash 11...11.
scriptGuardCbor :: Text
scriptGuardCbor =
    "82068201581c" <> Text.replicate 28 "11"

scriptGuardHash :: Text
scriptGuardHash =
    "b9114d0c8fcf4610e179afba560689b160b29a062643772105feb6e7"

-- | The hash of the guard clause on the key hash 11...11.
keyGuardHash :: Text
keyGuardHash =
    "7c11fec0e82c325085e055b9d3e829f12d1bcb41c3e2dd6dec8e8f54"

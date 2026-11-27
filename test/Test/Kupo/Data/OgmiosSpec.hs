-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

module Test.Kupo.Data.OgmiosSpec
    ( spec
    ) where

import Kupo.Prelude

import Data.Aeson
    ( (.=)
    )
import Data.List
    ( (!!)
    )
import Kupo.App.ChainSync.Ogmios
    ( intersectionNotFound
    )
import Kupo.Data.Cardano
    ( IsBlock (..)
    , UnsupportedSubTransactions (..)
    , hashScript
    , scriptHashToText
    )
import Kupo.Data.Ogmios
    ( NextBlockResponse (..)
    , PartialBlock
    , decodeFindIntersectionResponse
    , decodeNextBlockResponse
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

        it "accepts a Conway block" $ do
            let tx = Json.object
                    [ "id" .= txId
                    , "spends" .= ("inputs" :: Text)
                    , "inputs" .= ([] :: [Json.Value])
                    , "outputs" .= ([] :: [Json.Value])
                    ]
            withBlock (nextBlock "conway" [tx]) $ \blk ->
                checkSubTransactions blk `shouldSatisfy` isRight

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

-- | The witnessed scripts of a block, with their key and their own hash.
witnessedScriptHashes :: PartialBlock -> [(Text, Text)]
witnessedScriptHashes =
    fmap (\(scriptHash, script) -> (scriptHashToText scriptHash, scriptHashToText (hashScript script)))
        . foldBlock (\_ -> (<>) . Map.toList . witnessedScripts @PartialBlock) []

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
